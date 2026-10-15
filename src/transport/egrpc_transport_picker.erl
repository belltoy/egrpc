%% @doc The choice of a transport of a subchannel which the picker already chose.
%%
%% ```
%% global picker:    which endpoint?          (egrpc_picker)
%% transport picker: which connection of it?  (this module)
%% '''
%%
%% The subchannel publishes its row in `egrpc_transports': the transports which take calls and
%% their `SETTINGS_MAX_CONCURRENT_STREAMS', and an `atomics' with three slots for every possible
%% transport (`Size' is `max_connections'): the unary calls in flight at `Idx', the flag `draining'
%% at `Size + Idx' which a caller sets when it saw `goaway' or `closing', and the count of the
%% calls which were given to it at `2 * Size + Idx', for the scale down.
%%
%% The least loaded transport which is not draining and is under its limit is chosen. The limit
%% is the one of the peer and `max_streams_per_connection'. Only unary calls are counted, a stream
%% is not: the owner of a stream may be gone without giving it back.
-module(egrpc_transport_picker).

-include("egrpc_internal.hrl").

-export([pick/2, release/2, mark_draining/2, ref/3]).
-export([choose/4]).

-export_type([row/0, ref/0, reserved/0]).

%% The row of `egrpc_transports'.
-type row() :: {Key :: term(), SubPid :: pid(), Counters :: atomics:atomics_ref(), Size :: pos_integer(),
                Ready :: [{pos_integer(), pid(), non_neg_integer() | infinity}],
                egrpc_transport_pool:opts(), #egrpc_endpoint{}}.

%% What the attempt keeps of the choice: to give the place back, and to set the flag.
-type ref() :: {atomics:atomics_ref(), Size :: pos_integer(), Idx :: pos_integer()}.
-type reserved() :: {pid(), ref()}.

%% @doc Choose a transport of the row. `Count' reserves a place of the transport, atomically with
%% the check of the limit, until `release/2'.
-spec pick(row(), Count :: boolean()) -> {ok, reserved()} | none.
pick({_Key, SubPid, Counters, Size, Ready, Opts, _Endpoint}, Count) ->
    Soft = Opts#egrpc_transport_pool_opts.max_streams_per_connection,
    case choose(Counters, Size, [{I, P, limit(M, Soft)} || {I, P, M} <- Ready], Count) of
        {Idx, Pid} ->
            ok = atomics:add(Counters, 2 * Size + Idx, 1),
            ok = maybe_scale_up(SubPid, Counters, Idx, Pid, Ready, Opts, Size),
            {ok, {Pid, {Counters, Size, Idx}}};
        none ->
            %% all of them are full: ask for one more
            Size > 1 andalso Ready =/= [] andalso egrpc_subchannel:scale_up(SubPid),
            none
    end.

-spec release(reserved() | undefined, boolean()) -> ok.
release({_Pid, {Counters, _Size, Idx}}, true) -> atomics:sub(Counters, Idx, 1);
release(_, _) -> ok.

%% @doc The connection is closing: no call goes to it any more, until it is up again.
-spec mark_draining(ref(), term()) -> ok.
mark_draining({Counters, Size, Idx}, _Why) ->
    atomics:put(Counters, Size + Idx, 1).

%% @private
-spec ref(atomics:atomics_ref(), pos_integer(), pos_integer()) -> ref().
ref(Counters, Size, Idx) -> {Counters, Size, Idx}.

limit(infinity, auto) -> infinity;
limit(infinity, Soft) -> Soft;
limit(Max, auto) -> Max;
limit(Max, Soft) -> min(Max, Soft).

%% Ask for one more transport when this one is above the threshold of its capacity.
maybe_scale_up(_SubPid, _Counters, _Idx, _Pid, _Ready, _Opts, 1) ->
    ok;
maybe_scale_up(SubPid, Counters, Idx, _Pid, Ready, Opts, _Size) ->
    {Idx, _, Peer} = lists:keyfind(Idx, 1, Ready),
    case limit(Peer, Opts#egrpc_transport_pool_opts.max_streams_per_connection) of
        infinity ->
            ok;
        Limit ->
            Threshold = Opts#egrpc_transport_pool_opts.scale_up_threshold,
            case atomics:get(Counters, Idx) >= Limit * Threshold of
                true -> egrpc_subchannel:scale_up(SubPid);
                false -> ok
            end
    end.

%% @private
%% The connection with the fewest calls in flight of those which are not draining and are under the
%% limit. With `Count' the place is reserved: the least busy first, the next one when another
%% caller took the last place meanwhile.
-spec choose(atomics:atomics_ref(), pos_integer(), [{pos_integer(), pid(), non_neg_integer() | infinity}],
             boolean()) -> {pos_integer(), pid()} | none.
choose(Counters, Size, Conns, true) ->
    case choose(Counters, Size, Conns, none, infinity) of
        none ->
            none;
        {Idx, _Pid} = Best ->
            {_, _, Max} = lists:keyfind(Idx, 1, Conns),
            case reserve(Counters, Idx, Max) of
                true -> Best;
                false -> reserve_first(Counters, Size, Conns, Idx)
            end
    end;
choose(Counters, Size, Conns, false) ->
    choose(Counters, Size, Conns, none, infinity).

reserve_first(Counters, Size, Conns, TakenIdx) ->
    Sorted = lists:sort([
        {atomics:get(Counters, Idx), Idx, Pid, Max}
        || {Idx, Pid, Max} <- Conns, Idx =/= TakenIdx, atomics:get(Counters, Size + Idx) =:= 0
    ]),
    reserve_in_order(Counters, Sorted).

reserve_in_order(_Counters, []) ->
    none;
reserve_in_order(Counters, [{_, Idx, Pid, Max} | Rest]) ->
    case reserve(Counters, Idx, Max) of
        true -> {Idx, Pid};
        false -> reserve_in_order(Counters, Rest)
    end.

%% Increment first, then check: the check is on the value this caller got, so the limit holds
%% however many callers are at it. A caller which is over the limit gives its place back.
reserve(Counters, Idx, infinity) ->
    ok = atomics:add(Counters, Idx, 1),
    true;
reserve(Counters, Idx, Max) ->
    case atomics:add_get(Counters, Idx, 1) =< Max of
        true ->
            true;
        false ->
            ok = atomics:sub(Counters, Idx, 1),
            false
    end.

choose(_Counters, _Size, [], Best, _BestInflight) ->
    Best;
choose(Counters, Size, [{Idx, Pid, _Max} = C | Rest], Best, BestInflight) ->
    case can_take(Counters, Size, C) of
        false ->
            choose(Counters, Size, Rest, Best, BestInflight);
        true ->
            Inflight = atomics:get(Counters, Idx),
            case Inflight < BestInflight of
                true -> choose(Counters, Size, Rest, {Idx, Pid}, Inflight);
                false -> choose(Counters, Size, Rest, Best, BestInflight)
            end
    end.

can_take(Counters, Size, {Idx, _Pid, Max}) ->
    atomics:get(Counters, Size + Idx) =:= 0 andalso
        (Max =:= infinity orelse atomics:get(Counters, Idx) < Max).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%% Run `Fun' in `N' processes and collect the results. The processes spin on a flag until all of
%% them are running, so that they are on different schedulers when they start.
concurrently(N, Fun) ->
    Self = self(),
    Flag = atomics:new(1, []),
    Pids = [spawn_link(fun() ->
        ok = spin(Flag),
        Self ! {self(), Fun()}
    end) || _ <- lists:seq(1, N)],
    timer:sleep(5),
    ok = atomics:put(Flag, 1, 1),
    [receive {P, R} -> R end || P <- Pids].

spin(Flag) ->
    case atomics:get(Flag, 1) of
        0 -> spin(Flag);
        1 -> ok
    end.

%% A race is not hit by every run: the scenarios are repeated.
-define(ROUNDS, 200).

reserve_never_exceeds_max_test() ->
    Max = 1,
    Conns = [{1, self(), Max}],
    [begin
         A = atomics:new(3, [{signed, true}]),
         Results = concurrently(8, fun() -> choose(A, 1, Conns, true) end),
         ?assertEqual(Max, length([R || R <- Results, R =/= none])),
         ?assertEqual(Max, atomics:get(A, 1))
     end || _ <- lists:seq(1, ?ROUNDS)],
    ok.

reserve_falls_over_to_the_next_connection_test() ->
    Conns = [{1, c1, 1}, {2, c2, 1}],
    [begin
         A = atomics:new(6, [{signed, true}]),
         Results = concurrently(8, fun() -> choose(A, 2, Conns, true) end),
         Got = [R || R <- Results, R =/= none],
         ?assertEqual(2, length(Got)),
         ?assertEqual([1, 1], [atomics:get(A, 1), atomics:get(A, 2)])
     end || _ <- lists:seq(1, ?ROUNDS)],
    ok.

reserve_skips_a_draining_connection_test() ->
    A = atomics:new(6, [{signed, true}]),
    ok = atomics:put(A, 2 + 1, 1),
    ?assertEqual(none, choose(A, 2, [{1, c1, infinity}], true)),
    ?assertEqual(0, atomics:get(A, 1)).

reserve_without_a_limit_counts_test() ->
    A = atomics:new(3, [{signed, true}]),
    Results = concurrently(50, fun() -> choose(A, 1, [{1, c, infinity}], true) end),
    ?assertEqual(50, length([R || R <- Results, R =/= none])),
    ?assertEqual(50, atomics:get(A, 1)).

least_loaded_test() ->
    A = atomics:new(6, [{signed, true}]),
    ok = atomics:put(A, 1, 3),
    ok = atomics:put(A, 2, 1),
    ?assertEqual({2, c2}, choose(A, 2, [{1, c1, infinity}, {2, c2, infinity}], false)).

limit_test() ->
    ?assertEqual(infinity, limit(infinity, auto)),
    ?assertEqual(10, limit(infinity, 10)),
    ?assertEqual(5, limit(5, auto)),
    ?assertEqual(5, limit(5, 10)),
    ?assertEqual(10, limit(100, 10)).
-endif.
