%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2021 VMware, Inc. or its affiliates.  All rights reserved.

%% One rabbit_fifo_dlx_worker process exists per (source) quorum queue that has at-least-once dead lettering
%% enabled. The rabbit_fifo_dlx_worker process is co-located on the quorum queue leader node.
%% Its job is to consume from the quorum queue's 'discards' queue (containing dead lettered messages)
%% and to forward each dead lettered message at least once to every target queue.
%% This is in contrast to at-most-once semantics of rabbit_dead_letter:publish/5 which is
%% the only option for classic queues and was the only option for quorum queues in RMQ <= v3.9
%%
%% Some parts of this module resemble the channel process in the sense that it needs to keep track what messages
%% are consumed but not acked yet and what messages are published but not confirmed yet.
%% Compared to the channel process, this module is protocol independent since it does not deal with AMQP clients.
%%
%% This module consumes directly from the rabbit_fifo_dlx_client bypassing the rabbit_queue_type interface,
%% but publishes via the rabbit_queue_type interface.
%% While consuming via rabbit_queue_type interface would have worked in practice (by using a special consumer argument,
%% e.g. {<<"x-internal-queue">>, longstr, <<"discards">>}) using the rabbit_fifo_dlx_client directly provides
%% separation of concerns making things easier to test, to debug, and to understand.

-module(rabbit_fifo_dlx_worker).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").

-behaviour(gen_server).

-export([start_link/1]).
%% gen_server callbacks
-export([init/1, terminate/2, handle_continue/2,
         handle_cast/2, handle_call/3, handle_info/2,
         code_change/3, format_status/2]).

-define(HIBERNATE_AFTER, 4*60*1000).

-record(pending, {
          %% consumed_msg_id is not to be confused with consumer delivery tag.
          %% The latter represents a means for AMQP clients to (multi-)ack to a channel process.
          %% However, queues are not aware of delivery tags.
          %% This rabbit_fifo_dlx_worker does not have the concept of delivery tags because it settles (acks)
          %% message IDs directly back to the queue (and there is no AMQP consumer).
          consumed_msg_id :: non_neg_integer(),
          delivery :: rabbit_types:delivery(),
          reason :: rabbit_dead_letter:reason(),
          %% target queues for which publisher confirm has not been received yet
          unsettled = [] :: [rabbit_amqqueue:name()],
          %% target queues for which publisher rejection was received recently
          rejected = [] :: [rabbit_amqqueue:name()],
          %% target queues for which publisher confirm was received
          settled = [] :: [rabbit_amqqueue:name()],
          %% Number of times the message was published (i.e. rabbit_queue_type:deliver/3 invoked).
          %% Can be 0 if the message was never published (for example no route exists).
          publish_count = 0 :: non_neg_integer(),
          %% Epoch time in milliseconds when the message was last published (i.e. rabbit_queue_type:deliver/3 invoked).
          %% It can be 'undefined' if the message was never published (for example no route exists).
          last_published_at :: undefined | integer(),
          %% Epoch time in milliseconds when the message was consumed from the source quorum queue.
          %% This value never changes.
          %% It's mainly informational and meant for debugging to understand for how long the message
          %% is sitting around without having received all publisher confirms.
          consumed_at :: integer()
         }).

-record(state, {
          %% source queue
          queue_ref :: rabbit_amqqueue:name(),
          %% monitors source queue
          monitor_ref :: reference(),
          %% configured (x-)dead-letter-exchange of source queue
          exchange_ref :: rabbit_exchange:name() | undefined,
          %% configured (x-)dead-letter-routing-key of source queue
          routing_key,
          %% client of source queue
          dlx_client_state :: rabbit_fifo_dlx_client:state(),
          %% clients of target queues
          queue_type_state :: rabbit_queue_type:state(),
          %% Consumed messages for which we are awaiting publisher confirms.
          pendings = #{} :: #{OutSeq :: non_neg_integer() => #pending{}},
          %% Consumed message IDs for which we received all publisher confirms.
          settled_ids = [] :: [non_neg_integer()],
          %% next outgoing message sequence number
          next_out_seq = 1,
          %% If no publisher confirm was received for at least settle_timeout milliseconds, message will be redelivered.
          %% To prevent duplicates in the target queue and to ensure message will eventually be acked to the source queue,
          %% set this value higher than the maximum time it takes for a queue to settle a message.
          settle_timeout :: non_neg_integer(),
          %% Timer firing every settle_timeout milliseconds
          %% redelivering messages for which not all publisher confirms were received.
          %% If there are no pending messages, this timer will eventually be cancelled to allow
          %% this worker to hibernate.
          timer :: undefined | reference(),
          logged = #{} :: map()
         }).

-type state() :: #state{}.

start_link(QRef) ->
    gen_server:start_link(?MODULE, QRef, [{hibernate_after, ?HIBERNATE_AFTER}]).

-spec init(rabbit_amqqueue:name()) ->
    {ok, undefined, {continue, rabbit_amqqueue:name()}}.
init(QRef) ->
    {ok, undefined, {continue, QRef}}.

-spec handle_continue(rabbit_amqqueue:name(), undefined) ->
    {noreply, state()}.
handle_continue(QRef, undefined) ->
    {ok, Prefetch} = application:get_env(rabbit,
                                         dead_letter_worker_consumer_prefetch),
    {ok, SettleTimeout} = application:get_env(rabbit,
                                              dead_letter_worker_publisher_confirm_timeout),
    {ok, Q} = rabbit_amqqueue:lookup(QRef),
    {ClusterName, _MaybeOldLeaderNode} = amqqueue:get_pid(Q),
    {ok, ConsumerState} = rabbit_fifo_dlx_client:checkout(QRef,
                                                          {ClusterName, node()},
                                                          Prefetch),
    {noreply, lookup_topology(#state{queue_ref = QRef,
                                     queue_type_state = rabbit_queue_type:init(),
                                     settle_timeout = SettleTimeout,
                                     dlx_client_state = ConsumerState,
                                     monitor_ref = erlang:monitor(process, ClusterName)
                                    })}.

terminate(_Reason, State) ->
    cancel_timer(State).

handle_call(Request, From, State) ->
    rabbit_log:info("~s received unhandled call from ~p: ~p", [?MODULE, From, Request]),
    {noreply, State}.

handle_cast({queue_event, QRef, {_From, {machine, lookup_topology}}},
            #state{queue_ref = QRef} = State0) ->
    State = lookup_topology(State0),
    redeliver_and_ack(State);
handle_cast({queue_event, QRef, {From, Evt}},
            #state{queue_ref = QRef,
                   dlx_client_state = DlxState0} = State0) ->
    %% received dead-letter message from source queue
    {ok, DlxState, Actions} = rabbit_fifo_dlx_client:handle_ra_event(From, Evt, DlxState0),
    State1 = State0#state{dlx_client_state = DlxState},
    State = handle_queue_actions(Actions, State1),
    {noreply, State};
handle_cast({queue_event, QRef, Evt},
            #state{queue_type_state = QTypeState0} = State0) ->
    case rabbit_queue_type:handle_event(QRef, Evt, QTypeState0) of
        {ok, QTypeState1, Actions} ->
            %% received e.g. confirm from target queue
            State1 = State0#state{queue_type_state = QTypeState1},
            State = handle_queue_actions(Actions, State1),
            {noreply, State};
        eol ->
            remove_queue(QRef, State0);
        {protocol_error, _Type, _Reason, _Args} ->
            {noreply, State0}
    end;
handle_cast(settle_timeout, State0) ->
    State = State0#state{timer = undefined},
    redeliver_and_ack(State);
handle_cast(Request, State) ->
    rabbit_log:info("~s received unhandled cast ~p", [?MODULE, Request]),
    {noreply, State}.

redeliver_and_ack(State0) ->
    State1 = redeliver_messages(State0),
    State2 = ack(State1),
    State = maybe_set_timer(State2),
    {noreply, State}.

handle_info({'DOWN', Ref, process, _, _},
            #state{monitor_ref = Ref,
                   queue_ref = QRef}) ->
    %% Source quorum queue is down. Therefore, terminate ourself.
    %% The new leader will re-create another dlx_worker.
    rabbit_log:debug("~s terminating itself because leader of ~s is down...",
                     [?MODULE, rabbit_misc:rs(QRef)]),
    supervisor:terminate_child(rabbit_fifo_dlx_sup, self());
handle_info({'DOWN', _MRef, process, QPid, Reason},
            #state{queue_type_state = QTypeState0} = State0) ->
    %% received from target classic queue
    case rabbit_queue_type:handle_down(QPid, Reason, QTypeState0) of
        {ok, QTypeState, Actions} ->
            State = State0#state{queue_type_state = QTypeState},
            {noreply, handle_queue_actions(Actions, State)};
        {eol, QTypeState, QRef} ->
            remove_queue(QRef, State0#state{queue_type_state = QTypeState})
    end;
handle_info(Info, State) ->
    rabbit_log:info("~s received unhandled info ~p", [?MODULE, Info]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

remove_queue(QRef, #state{pendings = Pendings0,
                          queue_type_state = QTypeState0} = State) ->
    Pendings = maps:map(fun(_Seq, #pending{unsettled = Unsettled} = Pending) ->
                                Pending#pending{unsettled = lists:delete(QRef, Unsettled)}
                        end, Pendings0),
    QTypeState = rabbit_queue_type:remove(QRef, QTypeState0),
    %% Wait for max 1s (we don't want to block the gen_server process for a longer time)
    %% until target queue is deleted from ETS table to prevent subsequently consumed message(s)
    %% from being routed to a deleted target queue. (If that happens for a target quorum or
    %% stream queue and that queue gets re-created with the same name, these messages will
    %% be stuck in our 'pendings' state.)
    wait_for_queue_deleted(QRef, 20),
    {noreply, State#state{pendings = Pendings,
                          queue_type_state = QTypeState}}.

wait_for_queue_deleted(QRef, 0) ->
    rabbit_log:debug("Received deletion event for ~s but queue still exists in ETS table.",
                     [rabbit_misc:rs(QRef)]);
wait_for_queue_deleted(QRef, N) ->
    case rabbit_amqqueue:lookup(QRef) of
        {error, not_found} ->
            ok;
        _ ->
            timer:sleep(50),
            wait_for_queue_deleted(QRef, N-1)
    end.

-spec lookup_topology(state()) -> state().
lookup_topology(#state{queue_ref = {resource, Vhost, queue, _} = QRef} = State) ->
    {ok, Q} = rabbit_amqqueue:lookup(QRef),
    DLRKey = rabbit_queue_type_util:args_policy_lookup(<<"dead-letter-routing-key">>,
                                                       fun(_Pol, QArg) -> QArg end, Q),
    DLX = rabbit_queue_type_util:args_policy_lookup(<<"dead-letter-exchange">>,
                                                    fun(_Pol, QArg) -> QArg end, Q),
    DLXRef = rabbit_misc:r(Vhost, exchange, DLX),
    State#state{exchange_ref = DLXRef,
                routing_key = DLRKey}.

-spec handle_queue_actions(rabbit_queue_type:actions() | rabbit_fifo_dlx_client:actions(), state()) ->
    state().
handle_queue_actions(Actions, State0) ->
    lists:foldl(
      fun ({deliver, Msgs}, S0) ->
              S1 = handle_deliver(Msgs, S0),
              maybe_set_timer(S1);
          ({settled, QRef, MsgSeqs}, S0) ->
              S1 = handle_settled(QRef, MsgSeqs, S0),
              S2 = ack(S1),
              maybe_cancel_timer(S2);
          ({rejected, QRef, MsgSeqs}, S0) ->
              handle_rejected(QRef, MsgSeqs, S0);
          ({queue_down, _QRef}, S0) ->
              %% target classic queue is down, but not deleted
              S0
      end, State0, Actions).

handle_deliver(Msgs, #state{queue_ref = QRef} = State0)
  when is_list(Msgs) ->
    {DLX, State} = lookup_dlx(State0),
    lists:foldl(fun({_QRef, MsgId, Msg, Reason}, S) ->
                        forward(Msg, MsgId, QRef, DLX, Reason, S)
                end, State, Msgs).

handle_rejected(QRef, MsgSeqNos, #state{pendings = Pendings0} = State)
  when is_list(MsgSeqNos) ->
    Pendings = lists:foldl(fun(SeqNo, P) ->
                                   rejected(SeqNo, [QRef], P)
                           end, Pendings0, MsgSeqNos),
    State#state{pendings = Pendings}.

rejected(SeqNo, Qs, Pendings)
  when is_list(Qs) ->
    case maps:is_key(SeqNo, Pendings) of
        true ->
            maps:update_with(SeqNo,
                             fun(#pending{unsettled = Unsettled,
                                          rejected = Rejected} = P) ->
                                     P#pending{unsettled = Unsettled -- Qs,
                                               rejected = Qs ++ Rejected}
                             end,
                             Pendings);
        false ->
            rabbit_log:debug("Ignoring rejection for unknown sequence number ~b "
                             "from target dead letter queues ~p",
                             [SeqNo, Qs]),
            Pendings
    end.

-spec lookup_dlx(state()) ->
    {rabbit_types:exchange() | not_found, state()}.
lookup_dlx(#state{exchange_ref = DLXRef} = State0) ->
    case rabbit_exchange:lookup(DLXRef) of
        {error, not_found} ->
            State = log_missing_dlx_once(State0),
            {not_found, State};
        {ok, X} ->
            {X, State0}
    end.

-spec forward(rabbit_types:message(), non_neg_integer(), rabbit_amqqueue:name(),
              rabbit_types:exchange() | not_found, rabbit_dead_letter:reason(), state()) ->
    state().
forward(ConsumedMsg, ConsumedMsgId, ConsumedQRef, DLX, Reason,
        #state{next_out_seq = OutSeq,
               pendings = Pendings,
               exchange_ref = DLXRef,
               routing_key = RKey} = State0) ->
    #basic_message{routing_keys = RKeys} = Msg = rabbit_dead_letter:make_msg(ConsumedMsg, Reason,
                                                                             DLXRef, RKey, ConsumedQRef),
    %% Field 'mandatory' is set to false because we check ourselves whether the message is routable.
    Delivery = rabbit_basic:delivery(_Mandatory = false, _Confirm = true, Msg, OutSeq),
    {TargetQs, State3} = case DLX of
                             not_found ->
                                 {[], State0};
                             _ ->
                                 RouteToQs0 = rabbit_exchange:route(DLX, Delivery),
                                 {RouteToQs1, Cycles} = rabbit_dead_letter:detect_cycles(Reason, Msg, RouteToQs0),
                                 State1 = log_cycles(Cycles, RKeys, State0),
                                 RouteToQs = rabbit_amqqueue:lookup(RouteToQs1),
                                 State2 = case RouteToQs of
                                              [] ->
                                                  log_no_route_once(State1);
                                              _ ->
                                                  State1
                                          end,
                                 {RouteToQs, State2}
                         end,
    Now = os:system_time(millisecond),
    Pend0 = #pending{
               consumed_msg_id = ConsumedMsgId,
               consumed_at = Now,
               delivery = Delivery,
               reason = Reason
              },
    case TargetQs of
        [] ->
            %% We can't deliver this message since there is no target queue we can route to.
            %% We buffer this message and retry to send every settle_timeout milliseonds.
            State3#state{next_out_seq = OutSeq + 1,
                         pendings = maps:put(OutSeq, Pend0, Pendings)};
        _ ->
            Pend = Pend0#pending{publish_count = 1,
                                 last_published_at = Now,
                                 unsettled = queue_names(TargetQs)},
            State = State3#state{next_out_seq = OutSeq + 1,
                                 pendings = maps:put(OutSeq, Pend, Pendings)},
            deliver_to_queues(Delivery, TargetQs, State)
    end.

-spec deliver_to_queues(rabbit_types:delivery(), [amqqueue:amqqueue()], state()) ->
    state().
deliver_to_queues(#delivery{msg_seq_no = SeqNo} = Delivery, Qs, #state{queue_type_state = QTypeState0,
                                                                       pendings = Pendings} = State0) ->
    {State, Actions} = case rabbit_queue_type:deliver(Qs, Delivery, QTypeState0) of
                           {ok, QTypeState, Actions0} ->
                               {State0#state{queue_type_state = QTypeState}, Actions0};
                           {error, Reason} ->
                               %% rabbit_queue_type:deliver/3 does not tell us which target queue failed.
                               %% Therefore, reject all target queues. We need to reject them such that
                               %% we won't rely on rabbit_fifo_client to re-deliver on behalf of us
                               %% (and therefore preventing messages to get stuck in our 'unsettled' state).
                               QNames = queue_names(Qs),
                               rabbit_log:debug("Failed to deliver message with seq_no ~b to queues ~p: ~p",
                                                [SeqNo, QNames, Reason]),
                               {State0#state{pendings = rejected(SeqNo, QNames, Pendings)}, []}
                       end,
    handle_queue_actions(Actions, State).

handle_settled(QRef, MsgSeqs, State) ->
    lists:foldl(fun (MsgSeq, S) ->
                        handle_settled0(QRef, MsgSeq, S)
                end, State, MsgSeqs).

handle_settled0(QRef, MsgSeq, #state{pendings = Pendings,
                                     settled_ids = SettledIds} = State) ->
    case maps:find(MsgSeq, Pendings) of
        {ok, #pending{unsettled = [QRef],
                      rejected = [],
                      consumed_msg_id = ConsumedId}} ->
            State#state{pendings = maps:remove(MsgSeq, Pendings),
                        settled_ids = [ConsumedId | SettledIds]};
        {ok, #pending{unsettled = [],
                      rejected = [QRef],
                      consumed_msg_id = ConsumedId}} ->
            State#state{pendings = maps:remove(MsgSeq, Pendings),
                        settled_ids = [ConsumedId | SettledIds]};
        {ok, #pending{unsettled = Unsettled,
                      rejected = Rejected,
                      settled = Settled} = Pend0} ->
            Pend = Pend0#pending{unsettled = lists:delete(QRef, Unsettled),
                                 rejected = lists:delete(QRef, Rejected),
                                 settled = [QRef | Settled]},
            State#state{pendings = maps:update(MsgSeq, Pend, Pendings)};
        error ->
            rabbit_log:debug("Ignoring publisher confirm for unknown sequence number ~b "
                             "from target dead letter ~s",
                             [MsgSeq, rabbit_misc:rs(QRef)]),
            State
    end.

ack(#state{settled_ids = []} = State) ->
    State;
ack(#state{settled_ids = Ids,
           dlx_client_state = DlxState0} = State) ->
    {ok, DlxState} = rabbit_fifo_dlx_client:settle(Ids, DlxState0),
    State#state{settled_ids = [],
                dlx_client_state = DlxState}.

%% Re-deliver messages that
%% 1. timed out waiting on publisher confirm, or
%% 2. got rejected by target queue, or
%% 3. never got sent due to routing topology misconfiguration.
-spec redeliver_messages(state()) ->
    state().
redeliver_messages(#state{pendings = Pendings,
                          settle_timeout = SettleTimeout} = State0) ->
    case lookup_dlx(State0) of
        {not_found, State} ->
            %% Configured dead-letter-exchange does (still) not exist.
            %% Keep the same Pendings in our state until user creates or re-configures the dead-letter-exchange.
            State;
        {DLX, State} ->
            Now = os:system_time(millisecond),
            maps:fold(fun(OutSeq, #pending{last_published_at = LastPub} = Pend, S0)
                            when LastPub + SettleTimeout =< Now ->
                              %% Publisher confirm timed out.
                              redeliver(Pend, DLX, OutSeq, S0);
                         (OutSeq, #pending{last_published_at = undefined} = Pend, S0) ->
                              %% Message was never published due to dead-letter routing topology misconfiguration.
                              redeliver(Pend, DLX, OutSeq, S0);
                         (_OutSeq, _Pending, S) ->
                              %% Publisher confirm did not time out.
                              S
                      end, State, Pendings)
    end.

redeliver(#pending{delivery = #delivery{message = #basic_message{content = Content}}} = Pend,
          DLX, OutSeq, #state{routing_key = undefined} = State) ->
    %% No dead-letter-routing-key defined for source quorum queue.
    %% Therefore use all of messages's original routing keys (which can include CC and BCC recipients).
    %% This complies with the behaviour of the rabbit_dead_letter module.
    %% We stored these original routing keys in the 1st (i.e. most recent) x-death entry.
    #content{properties = #'P_basic'{headers = Headers}} =
    rabbit_binary_parser:ensure_content_decoded(Content),
    {array, [{table, MostRecentDeath}|_]} = rabbit_misc:table_lookup(Headers, <<"x-death">>),
    {<<"routing-keys">>, array, Routes0} = lists:keyfind(<<"routing-keys">>, 1, MostRecentDeath),
    Routes = [Route || {longstr, Route} <- Routes0],
    redeliver0(Pend, DLX, Routes, OutSeq, State);
redeliver(Pend, DLX, OutSeq, #state{routing_key = DLRKey} = State) ->
    redeliver0(Pend, DLX, [DLRKey], OutSeq, State).

redeliver0(#pending{delivery = #delivery{message = BasicMsg} = Delivery0,
                    unsettled = Unsettled0,
                    settled = Settled,
                    publish_count = PublishCount,
                    reason = Reason,
                    consumed_msg_id = ConsumedId} = Pend0,
           DLX, DLRKeys, OutSeq,
           #state{pendings = Pendings,
                  settled_ids = SettledIds,
                  exchange_ref = DLXRef,
                  queue_type_state = QTypeState} = State0)
  when is_list(DLRKeys) ->
    Delivery = Delivery0#delivery{message = BasicMsg#basic_message{exchange_name = DLXRef,
                                                                   routing_keys  = DLRKeys}},
    RouteToQs0 = rabbit_exchange:route(DLX, Delivery),
    %% rabbit_exchange:route/2 can route to target queues that do not exist (e.g. in case of default exchange).
    %% Therefore, filter out non-existent target queues.
    RouteToQs1 = queue_names(rabbit_amqqueue:lookup(RouteToQs0)),
    case {RouteToQs1, Settled} of
        {[], [_|_]} ->
            %% Routes changed dynamically so that we don't await any publisher confirms anymore.
            %% Since we also received at least once publisher confirm (mandatory flag semantics),
            %% we can ack the messasge to the source quorum queue.
            State0#state{pendings = maps:remove(OutSeq, Pendings),
                         settled_ids = [ConsumedId | SettledIds]};
        _ ->
            %% Do not redeliver message to a target queue
            %% 1. for which we already received a publisher confirm, or
            Unsettled = RouteToQs1 -- Settled,
            %% 2. whose queue client redelivers on our behalf.
            %% Note that a quorum queue client does not redeliver on our behalf if it previously
            %% rejected the message. This is why we always redeliver rejected messages here.
            RouteToQs2 = Unsettled -- clients_redeliver(Unsettled0, QTypeState),
            {RouteToQs, Cycles} = rabbit_dead_letter:detect_cycles(Reason, BasicMsg, RouteToQs2),
            State1 = log_cycles(Cycles, DLRKeys, State0),
            case RouteToQs of
                [] ->
                    State1;
                _ ->
                    Pend = Pend0#pending{publish_count = PublishCount + 1,
                                         last_published_at = os:system_time(millisecond),
                                         delivery = Delivery,
                                         %% Override 'unsettled' because topology could have changed.
                                         unsettled = Unsettled,
                                         %% Any target queue that rejected previously and still need
                                         %% to be routed to is moved back to 'unsettled'.
                                         rejected = []},
                    State = State0#state{pendings = maps:update(OutSeq, Pend, Pendings)},
                    deliver_to_queues(Delivery, rabbit_amqqueue:lookup(RouteToQs), State)
            end
    end.

%% Returns queues whose queue clients take care of redelivering messages.
-spec clients_redeliver([rabbit_amqqueue:name()], rabbit_queue_type:state()) ->
    [rabbit_amqqueue:name()].
clients_redeliver(Qs, QTypeState) ->
    lists:filter(fun(Q) ->
                         case rabbit_queue_type:module(Q, QTypeState) of
                             {ok, rabbit_quorum_queue} ->
                                 % If #enqueue{} Raft command does not get applied
                                 % rabbit_fifo_client will resend.
                                 true;
                             {ok, rabbit_stream_queue} ->
                                 true;
                             _ ->
                                 false
                         end
                 end, Qs).

maybe_set_timer(#state{timer = TRef} = State)
  when is_reference(TRef) ->
    State;
maybe_set_timer(#state{timer = undefined,
                       pendings = Pendings} = State)
  when map_size(Pendings) =:= 0 ->
    State;
maybe_set_timer(#state{timer = undefined,
                       settle_timeout = SettleTimeout} = State) ->
    TRef = erlang:send_after(SettleTimeout, self(), {'$gen_cast', settle_timeout}),
    State#state{timer = TRef}.

maybe_cancel_timer(#state{timer = TRef,
                          pendings = Pendings} = State)
  when is_reference(TRef),
       map_size(Pendings) =:= 0 ->
    erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
    State#state{timer = undefined};
maybe_cancel_timer(State) ->
    State.

cancel_timer(#state{timer = TRef} = State)
  when is_reference(TRef) ->
    erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
    State#state{timer = undefined};
cancel_timer(State) ->
    State.

queue_names(Qs)
  when is_list(Qs) ->
    lists:map(fun amqqueue:get_name/1, Qs).

format_status(_Opt, [_PDict, #state{
                                queue_ref = QueueRef,
                                exchange_ref = ExchangeRef,
                                routing_key = RoutingKey,
                                dlx_client_state = DlxClientState,
                                queue_type_state = QueueTypeState,
                                pendings = Pendings,
                                settled_ids = SettledIds,
                                next_out_seq = NextOutSeq,
                                settle_timeout = SettleTimeout,
                                timer = Timer,
                                logged = Logged
                               }]) ->
    S = #{queue_ref => QueueRef,
          exchange_ref => ExchangeRef,
          routing_key => RoutingKey,
          dlx_client_state => rabbit_fifo_dlx_client:overview(DlxClientState),
          queue_type_state => QueueTypeState,
          pendings => maps:map(fun(_, P) -> format_pending(P) end, Pendings),
          settled_ids => SettledIds,
          next_out_seq => NextOutSeq,
          settle_timeout => SettleTimeout,
          timer_is_active => Timer =/= undefined,
          logged => Logged},
    [{data, [{"State", S}]}].

format_pending(#pending{consumed_msg_id = ConsumedMsgId,
                        delivery = _DoNotLogLargeBinary,
                        reason = Reason,
                        unsettled = Unsettled,
                        rejected = Rejected,
                        settled = Settled,
                        publish_count = PublishCount,
                        last_published_at = LastPublishedAt,
                        consumed_at = ConsumedAt}) ->
    #{consumed_msg_id => ConsumedMsgId,
      reason => Reason,
      unsettled => Unsettled,
      rejected => Rejected,
      settled => Settled,
      publish_count => PublishCount,
      last_published_at => LastPublishedAt,
      consumed_at => ConsumedAt}.

log_missing_dlx_once(#state{exchange_ref = SameDlx,
                            logged = #{missing_dlx := SameDlx}} = State) ->
    State;
log_missing_dlx_once(#state{exchange_ref = DlxResource,
                            queue_ref = QueueResource,
                            logged = Logged} = State) ->
    rabbit_log:warning("Cannot forward any dead-letter messages from source quorum ~s because "
                       "its configured dead-letter-exchange ~s does not exist. "
                       "Either create the configured dead-letter-exchange or re-configure "
                       "the dead-letter-exchange policy for the source quorum queue to prevent "
                       "dead-lettered messages from piling up in the source quorum queue. "
                       "This message will not be logged again.",
                       [rabbit_misc:rs(QueueResource), rabbit_misc:rs(DlxResource)]),
    State#state{logged = maps:put(missing_dlx, DlxResource, Logged)}.

log_no_route_once(#state{exchange_ref = SameDlx,
                         routing_key = SameRoutingKey,
                         logged = #{no_route := {SameDlx, SameRoutingKey}}} = State) ->
    State;
log_no_route_once(#state{queue_ref = QueueResource,
                         exchange_ref = DlxResource,
                         routing_key = RoutingKey,
                         logged = Logged} = State) ->
    rabbit_log:warning("Cannot forward any dead-letter messages from source quorum ~s "
                       "with configured dead-letter-exchange ~s and configured "
                       "dead-letter-routing-key '~s'. This can happen either if the dead-letter "
                       "routing topology is misconfigured (for example no queue bound to "
                       "dead-letter-exchange or wrong dead-letter-routing-key configured) or if "
                       "non-mirrored classic queues are bound whose host node is down. "
                       "Fix this issue to prevent dead-lettered messages from piling up "
                       "in the source quorum queue. "
                       "This message will not be logged again.",
                       [rabbit_misc:rs(QueueResource), rabbit_misc:rs(DlxResource), RoutingKey]),
    State#state{logged = maps:put(no_route, {DlxResource, RoutingKey}, Logged)}.

log_cycles(Cycles, RoutingKeys, State) ->
    lists:foldl(fun(Cycle, S) -> log_cycle_once(Cycle, RoutingKeys, S) end, State, Cycles).

log_cycle_once(Queues, _, #state{logged = Logged} = State)
  when is_map_key({cycle, Queues}, Logged) ->
    State;
log_cycle_once(Queues, RoutingKeys, #state{exchange_ref = DlxResource,
                                           queue_ref = QueueResource,
                                           logged = Logged} = State) ->
    rabbit_log:warning("Dead-letter queues cycle detected for source quorum ~s "
                       "with dead-letter exchange ~s and routing keys ~p: ~p "
                       "This message will not be logged again.",
                       [rabbit_misc:rs(QueueResource), rabbit_misc:rs(DlxResource),
                        RoutingKeys, Queues]),
    State#state{logged = maps:put({cycle, Queues}, true, Logged)}.