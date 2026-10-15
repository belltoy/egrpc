%% @doc One network attempt of a logical call: build its metadata, pick a subchannel and a
%% transport of it, open the stream. Every attempt picks again, it never keeps what the one
%% before chose.
%%
%% ```
%% Attempt: credentials -> picker (subchannel) -> transport picker (transport) -> stream
%% '''
-module(egrpc_attempt).

-feature(maybe_expr, enable).

-include("egrpc_internal.hrl").
-include_lib("kernel/include/logger.hrl").

-export([unary/4, open_stream/3]).
-export([done/6]).
-export([number/1, subchannel/1, endpoint/1, start_time/1, call_id/1, metadata/1, deadline/1]).

-export_type([info/0]).

-type info() :: #egrpc_attempt{}.

%% The headers of every request, the `content-type' is the one of the codec.
-define(DEFAULT_HEADERS, [
    {<<"grpc-encoding">>, <<"identity">>},
    {<<"te">>, <<"trailers">>}
]).

-define(DEADLINE_EXCEEDED,
        {grpc_error, deadline_exceeded, <<"The deadline of the call has passed">>}).

%% The wait of a call which is waiting for a place of a transport which is not there yet.
-define(SATURATED_WAIT, 10).

%% @private
%% @doc A unary attempt. `Previous' are the subchannels of the attempts before. The attempt which
%% is returned has the subchannel which was used, `undefined' when none was picked.
-spec unary(egrpc_call:call(), map(), non_neg_integer(), [term()]) ->
    {{ok, map()} | {ok, map(), map()} | {error, term()}, info()}.
unary(Call, Request, Number, Previous) ->
    case begin_attempt(Call, Number, Previous, true) of
        {ok, Stream} ->
            {Result0, Stream1} = try egrpc_stream:unary(Stream, Request)
                                 after egrpc_stream:release(Stream)
                                 end,
            Result = case Result0 of
                {ok, Resp, Meta} ->
                    ok = finish_ok(Stream1),
                    case maps:get(with_metadata, egrpc_call:opts(Call), false) of
                        true -> {ok, Resp, Meta};
                        false -> {ok, Resp}
                    end;
                {error, Reason} ->
                    ok = finish_error(Stream1, Reason),
                    {error, Reason}
            end,
            {Result, egrpc_stream:attempt(Stream1)};
        {error, Reason, Attempt} ->
            {{error, Reason}, Attempt}
    end.

finish_ok(Stream) ->
    Trailers = maps:get(trailers, egrpc_stream:attributes(Stream), []),
    _ = egrpc_stream:finish(Stream, {ok, Trailers}, ok),
    ok.

finish_error(Stream, Reason) ->
    _ = egrpc_stream:finish(Stream, {error, Reason}, {error, Reason}),
    ok.

%% @private
%% @doc The stream of a streaming call, the request is not sent.
-spec open_stream(egrpc_call:call(), non_neg_integer(), [term()]) ->
    {ok, egrpc_stream:stream()} | {error, term()}.
open_stream(Call, Number, Previous) ->
    case begin_attempt(Call, Number, Previous, false) of
        {ok, Stream} -> {ok, Stream};
        {error, Reason, _Attempt} -> {error, Reason}
    end.

%% @private
%% The feedback of the attempt to the picker.
-spec done(info(), undefined | fun((#egrpc_pick_done{}) -> ok), egrpc_status:status(),
           [{binary(), binary()}], non_neg_integer(), non_neg_integer()) -> ok.
done(_Attempt, undefined, _Status, _Trailers, _Sent, _Received) ->
    ok;
done(#egrpc_attempt{start_time = Start}, Done, #egrpc_status{code = Code}, Trailers, Sent, Received) ->
    Latency = erlang:monotonic_time(microsecond) - Start,
    Feedback = #egrpc_pick_done{
        status = Code,
        latency_us = Latency,
        bytes_sent = Sent,
        bytes_received = Received,
        trailers = Trailers
    },
    %% the feedback of a picker must not change the result of a call
    try
        Done(Feedback)
    catch
        Class:Reason:Stacktrace ->
            ?LOG_WARNING(#{what => pick_done_failed, class => Class, reason => Reason,
                           stacktrace => Stacktrace})
    end,
    ok.

-spec number(info()) -> non_neg_integer().
number(#egrpc_attempt{number = N}) -> N.

%% @doc The id of the subchannel the attempt used, `undefined' when it did not get one.
-spec subchannel(info()) -> term().
subchannel(#egrpc_attempt{subchannel = Id}) -> Id.

-spec endpoint(info()) -> undefined | #egrpc_endpoint{}.
endpoint(#egrpc_attempt{endpoint = Endpoint}) -> Endpoint.

%% @doc `erlang:monotonic_time(microsecond)' of the start.
-spec start_time(info()) -> integer().
start_time(#egrpc_attempt{start_time = T}) -> T.

-spec call_id(info()) -> reference().
call_id(#egrpc_attempt{call_id = Id}) -> Id.

-spec metadata(info()) -> [{binary(), binary()}].
metadata(#egrpc_attempt{metadata = Metadata}) -> Metadata.

-spec deadline(info()) -> egrpc_deadline:deadline().
deadline(#egrpc_attempt{deadline = Deadline}) -> Deadline.

%%--------------------------------------------------------------------

begin_attempt(Call, Number, Previous, Count) ->
    Attempt0 = #egrpc_attempt{
        call_id = egrpc_call:id(Call),
        number = Number,
        start_time = erlang:monotonic_time(microsecond),
        deadline = egrpc_call:deadline(Call)
    },
    #egrpc_channel_ref{options = ChOpts} = egrpc_call:channel(Call),
    AttemptHooks = maps:get(attempt_hooks, ChOpts, []),
    case start(Call, Attempt0, Previous, Count, ChOpts, AttemptHooks) of
        {error, Reason, Info} = Error ->
            %% An attempt which did not start still is an attempt for the observers.
            ok = egrpc_attempt_hooks:start(AttemptHooks, Info),
            ok = egrpc_attempt_hooks:'end'(AttemptHooks, Info, {error, egrpc_status:from_error(Reason)}),
            Error;
        {ok, _} = Ok ->
            Ok
    end.

start(Call, Attempt0, Previous, Count, ChOpts, AttemptHooks) ->
    maybe
        ok ?= check_deadline(Call),
        {ok, Metadata} ?= metadata(Call, Attempt0#egrpc_attempt.number),
        {ok, SubId, Endpoint, Done, Reserved, Pid, Counters} ?=
            pick(Call, Attempt0#egrpc_attempt.number, Previous, Count),
        Attempt = Attempt0#egrpc_attempt{subchannel = SubId, endpoint = Endpoint, metadata = Metadata},
        Transport = maps:get(transport, ChOpts, egrpc_transport_http2),
        case Transport:open_stream(Pid, headers(Call, Metadata), #{path => egrpc_call:method(Call)}) of
            {ok, TStream} ->
                ok = egrpc_attempt_hooks:start(AttemptHooks, Attempt),
                {ok, egrpc_stream:new(#{
                    call => Call,
                    attempt => Attempt,
                    transport => Transport,
                    tstream => TStream,
                    conn => Pid,
                    reserved => Reserved,
                    counters => Counters,
                    done => Done,
                    hooks => maps:get(stream_hooks, ChOpts, []),
                    attempt_hooks => AttemptHooks,
                    unary => Count
                })};
            {error, OpenReason} ->
                ok = egrpc_transport_picker:release(Reserved, Count),
                {error, OpenReason, Attempt}
        end
    else
        {error, Reason} -> {error, Reason, Attempt0}
    end.

check_deadline(Call) ->
    case egrpc_deadline:expired(egrpc_call:deadline(Call)) of
        true -> {error, ?DEADLINE_EXCEEDED};
        false -> ok
    end.

%% The metadata of the attempt: the credentials, the metadata of the call on top of them.
metadata(Call, Number) ->
    Info = #{
        method => egrpc_call:method(Call),
        service => egrpc_call:service(Call),
        attempt => Number,
        info => egrpc_call:info(Call)
    },
    case egrpc_credentials:metadata(egrpc_call:credentials(Call), Info) of
        {ok, Creds} ->
            %% what the protocol sets is not the metadata of the application, wherever it came from
            {ok, egrpc_metadata:custom(egrpc_metadata:merge(Creds, egrpc_call:metadata(Call)))};
        {error, Reason} ->
            {error, {call_credentials, Reason}}
    end.

headers(Call, Metadata) ->
    #egrpc_channel_ref{options = ChOpts} = egrpc_call:channel(Call),
    ContentType = egrpc_codec:content_type(maps:get(codec, ChOpts, egrpc_proto)),
    Protocol = [{<<"content-type">>, ContentType} | ?DEFAULT_HEADERS],
    Timeout = case egrpc_deadline:header(egrpc_call:deadline(Call)) of
        undefined -> [];
        Header -> [{<<"grpc-timeout">>, Header}]
    end,
    %% what the protocol sets can not be replaced by the metadata
    Metadata ++ Timeout ++ Protocol.

%% The subchannel of the picker and a transport of it. A call which waits for ready waits for a
%% new picker when there is none.
pick(Call, Number, Previous, Count) ->
    Channel = egrpc_call:channel(Call),
    Info = #egrpc_pick_info{
        method = egrpc_call:method(Call),
        attempt = Number,
        previous_subchannels = Previous,
        call_attributes = egrpc_call:attributes(Call)
    },
    pick_loop(Call, Channel, Info, [], Count).

pick_loop(Call, Channel, Info, Tried, Count) ->
    case egrpc_channel:picker(Channel) of
        {ok, Version, Picker, _Connectivity} ->
            case egrpc_picker:pick(Picker, Info#egrpc_pick_info{
                    previous_subchannels = Info#egrpc_pick_info.previous_subchannels ++ Tried}) of
                {ok, #egrpc_pick_result{subchannel = SubId, done = Done}} ->
                    case lists:member(SubId, Tried) of
                        true ->
                            %% the picker has nothing else
                            unavailable(Call, Channel, Info, Tried, Count, Version, saturated);
                        false ->
                            transport(Call, Channel, Info, Tried, Count, SubId, Done)
                    end;
                {error, Reason} ->
                    unavailable(Call, Channel, Info, Tried, Count, Version, Reason)
            end;
        {error, channel_not_found} ->
            {error, channel_not_found}
    end.

transport(Call, #egrpc_channel_ref{id = Name} = Channel, Info, Tried, Count, SubId, Done) ->
    case ets:lookup(egrpc_transports, {Name, SubId}) of
        [{_, _, _, _, _, _, Endpoint} = Row] ->
            case egrpc_transport_picker:pick(Row, Count) of
                {ok, {Pid, {Counters, Size, Idx}} = Reserved} ->
                    {ok, SubId, Endpoint, Done, case Count of true -> Reserved; false -> undefined end,
                     Pid, egrpc_transport_picker:ref(Counters, Size, Idx)};
                none ->
                    %% the transports of the subchannel are full or not up: another subchannel
                    pick_loop(Call, Channel, Info, [SubId | Tried], Count)
            end;
        [] ->
            pick_loop(Call, Channel, Info, [SubId | Tried], Count)
    end.

%% Nothing can take the call. It fails at once, or waits for the picker to change.
unavailable(Call, Channel, Info, Tried, Count, Version, Reason) ->
    case egrpc_call:wait_for_ready(Call) of
        false ->
            {error, unavailable_error(Reason)};
        true ->
            Wait = case Tried of
                [] -> egrpc_call:remaining(Call);
                _ -> min(?SATURATED_WAIT, egrpc_call:remaining(Call))
            end,
            case Wait of
                0 ->
                    {error, ?DEADLINE_EXCEEDED};
                _ when Tried =/= [] ->
                    %% some subchannel is ready but full: the transports change without a
                    %% new picker, so look again after a moment
                    timer:sleep(Wait),
                    pick_loop(Call, Channel, Info, [], Count);
                _ ->
                    case egrpc_channel:wait_picker(Channel, Version, Wait) of
                        ok -> pick_loop(Call, Channel, Info, [], Count);
                        {error, timeout} -> {error, ?DEADLINE_EXCEEDED};
                        {error, channel_not_found} -> {error, channel_not_found}
                    end
            end
    end.

unavailable_error(Reason) ->
    {grpc_error, unavailable, iolist_to_binary(io_lib:format("No subchannel is ready: ~0p", [Reason]))}.
