%% @doc The transports of one subchannel: all of them to the same endpoint.
%%
%% This is a plain data structure which the subchannel owns. The choice of the endpoint is the
%% one of the picker, the choice of the transport of the endpoint is `m:egrpc_transport_picker'.
%%
%% A transport has a slot `1..max_connections', which is also its place in the `atomics' of the
%% subchannel. The pool starts with `min_connections' of them, `scale_up/1' takes one more when
%% they are saturated, and `scale_down' candidates are the transports which were idle for
%% `idle_timeout_ms'. A transport which is `draining' is not given new calls, the ones which it
%% has are not touched.
-module(egrpc_transport_pool).

-include("egrpc_internal.hrl").

-export([opts/1, new/1, max_connections/1, min_connections/1, opts_of/1]).
-export([lookup/2, store/2, remove/2, by_pid/2, to_list/1]).
-export([ready/1, count/1, free_slot/1, connectivity/1]).

-export_type([pool/0, opts/0]).

-record(pool, {
    opts :: #egrpc_transport_pool_opts{},
    transports = #{} :: #{pos_integer() => #egrpc_transport_ref{}}
}).

-type pool() :: #pool{}.
-type opts() :: #egrpc_transport_pool_opts{}.

%% @doc The options from the map of the `transport_pool' option of a channel.
-spec opts(map()) -> opts().
opts(Map) when is_map(Map) ->
    Default = #egrpc_transport_pool_opts{},
    Min = maps:get(min_connections, Map, Default#egrpc_transport_pool_opts.min_connections),
    Max = maps:get(max_connections, Map, max(Min, Default#egrpc_transport_pool_opts.max_connections)),
    (is_integer(Min) andalso Min > 0) orelse error({invalid_option, {min_connections, Min}}),
    (is_integer(Max) andalso Max >= Min) orelse error({invalid_option, {max_connections, Max}}),
    Threshold = maps:get(scale_up_threshold, Map, Default#egrpc_transport_pool_opts.scale_up_threshold),
    (is_number(Threshold) andalso Threshold > 0 andalso Threshold =< 1)
        orelse error({invalid_option, {scale_up_threshold, Threshold}}),
    Soft = maps:get(max_streams_per_connection, Map, auto),
    (Soft =:= auto orelse (is_integer(Soft) andalso Soft > 0))
        orelse error({invalid_option, {max_streams_per_connection, Soft}}),
    #egrpc_transport_pool_opts{
        min_connections = Min,
        max_connections = Max,
        scale_up_threshold = Threshold,
        idle_timeout_ms = maps:get(idle_timeout, Map, Default#egrpc_transport_pool_opts.idle_timeout_ms),
        max_streams_per_connection = Soft
    }.

-spec opts_of(pool()) -> opts().
opts_of(#pool{opts = Opts}) -> Opts.

-spec new(opts()) -> pool().
new(#egrpc_transport_pool_opts{} = Opts) ->
    #pool{opts = Opts}.

max_connections(#pool{opts = #egrpc_transport_pool_opts{max_connections = Max}}) -> Max.
min_connections(#pool{opts = #egrpc_transport_pool_opts{min_connections = Min}}) -> Min.

-spec lookup(pos_integer(), pool()) -> undefined | #egrpc_transport_ref{}.
lookup(Idx, #pool{transports = T}) -> maps:get(Idx, T, undefined).

-spec store(#egrpc_transport_ref{}, pool()) -> pool().
store(#egrpc_transport_ref{id = Idx} = Ref, #pool{transports = T} = Pool) ->
    Pool#pool{transports = T#{Idx => Ref}}.

-spec remove(pos_integer(), pool()) -> pool().
remove(Idx, #pool{transports = T} = Pool) ->
    Pool#pool{transports = maps:remove(Idx, T)}.

-spec by_pid(pid(), pool()) -> undefined | #egrpc_transport_ref{}.
by_pid(Pid, #pool{transports = T}) ->
    case [R || #egrpc_transport_ref{pid = P} = R <- maps:values(T), P =:= Pid] of
        [Ref | _] -> Ref;
        [] -> undefined
    end.

-spec to_list(pool()) -> [#egrpc_transport_ref{}].
to_list(#pool{transports = T}) ->
    [R || _ := R <- maps:iterator(T, ordered)].

%% @doc The transports which take new calls.
-spec ready(pool()) -> [#egrpc_transport_ref{}].
ready(Pool) ->
    [R || #egrpc_transport_ref{state = ready, draining = false} = R <- to_list(Pool)].

%% @doc How many slots are in use, the ones of transports which are going away are not.
-spec count(pool()) -> non_neg_integer().
count(Pool) ->
    length([R || #egrpc_transport_ref{state = S} = R <- to_list(Pool), S =/= draining, S =/= closed,
                 R =/= undefined]).

%% @doc The lowest slot which is not used, `none' when the pool has `max_connections'.
-spec free_slot(pool()) -> pos_integer() | none.
free_slot(#pool{opts = #egrpc_transport_pool_opts{max_connections = Max}, transports = T}) ->
    case [I || I <- lists:seq(1, Max), not maps:is_key(I, T)] of
        [I | _] -> I;
        [] -> none
    end.

%% @doc The connectivity of the endpoint: `ready' when at least one transport takes calls, so the
%% failure of one transport does not make the subchannel fail while another one is up.
-spec connectivity(pool()) -> egrpc_balancer:conn_state().
connectivity(#pool{transports = T} = Pool) ->
    case {ready(Pool), maps:size(T)} of
        {[_ | _], _} ->
            ready;
        {[], 0} ->
            idle;
        {[], _} ->
            case [R || #egrpc_transport_ref{state = connecting} = R <- to_list(Pool)] of
                [_ | _] -> connecting;
                [] -> transient_failure
            end
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

ref(Idx, State) -> #egrpc_transport_ref{id = Idx, state = State}.

opts_test() ->
    ?assertEqual(#egrpc_transport_pool_opts{}, opts(#{})),
    ?assertMatch(#egrpc_transport_pool_opts{min_connections = 2, max_connections = 2}, opts(#{min_connections => 2})),
    ?assertMatch(#egrpc_transport_pool_opts{max_connections = 4}, opts(#{max_connections => 4})),
    ?assertError({invalid_option, {max_connections, 1}}, opts(#{min_connections => 2, max_connections => 1})),
    ?assertError({invalid_option, {min_connections, 0}}, opts(#{min_connections => 0})),
    ?assertError({invalid_option, {scale_up_threshold, 2}}, opts(#{scale_up_threshold => 2})).

connectivity_test() ->
    P0 = new(opts(#{max_connections => 3})),
    ?assertEqual(idle, connectivity(P0)),
    P1 = store(ref(1, connecting), P0),
    ?assertEqual(connecting, connectivity(P1)),
    P2 = store(ref(2, down), P1),
    ?assertEqual(connecting, connectivity(P2)),
    P3 = store(ref(1, down), P2),
    ?assertEqual(transient_failure, connectivity(P3)),
    %% one ready transport is enough, whatever the others do
    P4 = store(ref(2, ready), P3),
    ?assertEqual(ready, connectivity(P4)),
    %% a draining one does not take calls
    P5 = store((ref(2, ready))#egrpc_transport_ref{draining = true}, P3),
    ?assertEqual(transient_failure, connectivity(P5)).

slots_test() ->
    P0 = new(opts(#{max_connections => 2})),
    ?assertEqual(1, free_slot(P0)),
    P1 = store(ref(1, ready), P0),
    ?assertEqual(2, free_slot(P1)),
    P2 = store(ref(2, ready), P1),
    ?assertEqual(none, free_slot(P2)),
    ?assertEqual(2, count(P2)),
    P3 = remove(1, P2),
    ?assertEqual(1, free_slot(P3)),
    ?assertEqual(1, count(P3)).
-endif.
