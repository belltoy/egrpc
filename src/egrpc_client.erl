%% @doc A client: several targets, a fixed number of connections to each, and the choice of one
%% for every call.
%%
%% ```
%% ok = egrpc_client:start(orders, #{
%%     targets => [#{id => a, host => "10.0.0.1", port => 50051}],
%%     pool_size => 4
%% }),
%% ok = egrpc_client:await_ready(orders, 5000),
%% {ok, Response} = my_client:method(orders, Request).
%% '''
%%
%% The name is given to the generated clients and to `m:egrpc_stub' where a channel goes. The call
%% is made in the process of the caller: the target and the connection are chosen from `ets' and
%% `atomics', and no process is on the path of a call.
%%
%% Options of `start/2':
%% - `targets': `[#{id := term(), host := string(), port := inet:port_number(), attrs => map()}]';
%%   `attrs' `#{standby => true}' is a target which is only used when a call names it with
%%   `hint => #{target => Id}' in its options;
%% - `pool_size': the connections to each target, 4 by default;
%% - `balancer': `round_robin' (default), `pick_first', or `{Module, Opts}' which implements
%%   `m:egrpc_balancer';
%% - `reconnect_backoff': `#{initial, max, multiplier, jitter}' in milliseconds, `1000', `30000',
%%   `1.6' and `0.2' by default;
%% - `conn_opts': `interceptors', `call_credentials', `codec', `info', `gun_opts' and `http2' of
%%   `egrpc_stub:open/3';
%% - `retry': `#{max_attempts, initial_backoff, max_backoff, multiplier}', `3', `50', `1000' and `2'
%%   by default (milliseconds). Without it a call is made once. See "Retries" below;
%% - `retry_budget': `#{max_tokens, token_ratio}', `100' and `0.1' by default, only with `retry'.
%%
%% == Retries ==
%%
%% A unary call is made again on another target when the request was not sent (`{transport,
%% not_sent}' of `egrpc_error:class/1': the server went away with `GOAWAY', refused the stream, or
%% gun refused it because the connection is closing). That is done once for a call, at once, and
%% it does not use the budget.
%%
%% When the request may have been processed (`{transport, unknown}', or the status `unavailable')
%% the call is made again only when the method is `IDEMPOTENT' or `NO_SIDE_EFFECTS' in its proto,
%% up to `max_attempts', after a wait of a random time up to `initial_backoff * multiplier^(n-1)'
%% (at most `max_backoff'). The calls of a target share a budget: a failure takes one token and a
%% success gives back `token_ratio', and nothing is retried while the target has half of
%% `max_tokens' or fewer. The `deadline' of the call is shared by all the attempts.
%%
%% FIXME: this is done around the call and not in an interceptor because the connection is chosen
%% before the interceptors run, and `Next' of an interceptor can not choose another one. An
%% interceptor which can would need `Next' to take `excluded'.
%%
%% The options of a call: `excluded' is a list of ids of targets which are not used, `hint' is
%% `#{target => Id}', and the ones of `egrpc_stub:opts()'.
-module(egrpc_client).

-behaviour(gen_server).

-export([start/2, stop/1, stop/2, set_targets/2, targets/1, await_ready/2]).
-export([unary/4, server_streaming/4, client_streaming/3, bidi_streaming/3]).
-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, handle_continue/2]).

-export_type([target/0, start_opts/0, call_opts/0]).

%% What a call of a client takes besides the options of `egrpc_stub:opts()'.
-type call_opts() :: #{excluded => [term()], hint => #{target => term()}, atom() => term()}.

-type target() :: #{
    id := term(),
    host := string(),
    port := inet:port_number(),
    attrs => map()
}.

-type start_opts() :: #{
    targets => [target()],
    pool_size => pos_integer(),
    balancer => egrpc_balancer:strategy(),
    reconnect_backoff => #{
        initial => non_neg_integer(),
        max => non_neg_integer(),
        multiplier => number(),
        jitter => number()
    },
    conn_opts => egrpc_stub:conn_opts(),
    retry => map(),
    retry_budget => map()
}.

-define(START_OPTS, [targets, pool_size, balancer, reconnect_backoff, conn_opts, retry, retry_budget]).
-define(DEFAULT_POOL_SIZE, 4).

%%--------------------------------------------------------------------
%% API

%% @doc Start the client `Name'. The connections are made in the background, a target which can not
%% be reached is tried again with backoff and `start/2' does not wait for it, see `await_ready/2'.
%%
%% Returns `{error, {already_started, Pid}}' when the name is taken. An option which is not valid
%% raises an error.
-spec start(egrpc:client_name(), start_opts()) -> ok | {error, term()}.
start(Name, Opts) when is_atom(Name), is_map(Opts) ->
    Config = validate(Opts),
    %% the options of the connections are checked here and not in the process of the client
    _ = egrpc_stub:client_channel(maps:get(conn_opts, Config)),
    case egrpc_registry:insert(Name, maps:remove(targets, Config), maps:get(targets, Config)) of
        ok ->
            case supervisor:start_child(egrpc_clients_sup, [Name]) of
                {ok, SupPid} ->
                    ok = egrpc_registry:set_sup(Name, SupPid);
                {error, Reason} ->
                    ok = egrpc_registry:delete(Name),
                    {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end.

%% @equiv stop(Name, 5000)
-spec stop(egrpc:client_name()) -> ok | {error, client_not_found}.
stop(Name) -> stop(Name, 5000).

%% @doc Stop the client: the opposite of `start/2'.
%%
%% The name is removed first, so a call from then on returns `{error, client_not_found}'. The unary
%% calls which are in flight are given up to `Timeout' ms to return, then the connections are
%% closed. A stream which is open fails with `closed'.
-spec stop(egrpc:client_name(), timeout()) -> ok | {error, client_not_found}.
stop(Name, Timeout) ->
    case egrpc_registry:lookup(Name) of
        not_found ->
            {error, client_not_found};
        {ok, {_, _, _, SupPid, _}} ->
            Counters = [{C, Size} || {_, _, _, _, Size, C, _} <- rows(Name)],
            %% No new call finds the client from here on.
            true = ets:delete(egrpc_index, Name),
            true = ets:delete(egrpc_clients, Name),
            ok = wait_drained(Counters, deadline(Timeout)),
            _ = case is_pid(SupPid) of
                true -> supervisor:terminate_child(egrpc_clients_sup, SupPid);
                false -> ok
            end,
            ok = egrpc_registry:delete(Name)
    end.

%% @doc Replace the targets of the client. A target is the same when its `id' is, a new one gets
%% connections, one which is not given any more has its connections closed (the streams on them
%% fail with `closed'), and a change of `attrs' only does not touch the connections.
-spec set_targets(egrpc:client_name(), [target()]) -> ok | {error, client_not_found}.
set_targets(Name, Targets0) ->
    Targets = validate_targets(Targets0),
    case egrpc_registry:set_targets(Name, Targets) of
        not_found ->
            {error, client_not_found};
        ok ->
            %% The registry has them, a client which is not there reads them when it starts.
            case egrpc_registry:lookup(Name) of
                {ok, {_, _, _, _, Pid}} when is_pid(Pid) ->
                    try gen_server:call(Pid, reload, 30000)
                    catch exit:_ -> ok
                    end;
                _ ->
                    ok
            end
    end.

%% @doc The targets of the client and whether they have a connection which is up.
-spec targets(egrpc:client_name()) ->
    [#{id := term(), state := ready | down, attrs := map()}] | {error, client_not_found}.
targets(Name) ->
    case egrpc_registry:lookup(Name) of
        not_found ->
            {error, client_not_found};
        {ok, {_, _, Targets, _, _}} ->
            [
                #{
                    id => Id,
                    attrs => maps:get(attrs, Target, #{}),
                    state => case ets:lookup(egrpc_rows, {Name, Id}) of
                        [{_, _, _, _, _, _, [_ | _]}] -> ready;
                        _ -> down
                    end
                }
                || #{id := Id} = Target <- Targets
            ]
    end.

%% @doc Wait until at least one connection of at least one target is up. When it returns
%% `{error, timeout}' the client keeps trying, stop it with `stop/1' if it is not wanted.
-spec await_ready(egrpc:client_name(), timeout()) ->
    ok | {error, timeout | client_not_found}.
await_ready(Name, Timeout) ->
    await_ready_loop(Name, deadline(Timeout)).

await_ready_loop(Name, Deadline) ->
    case ets:member(egrpc_clients, Name) of
        false ->
            {error, client_not_found};
        true ->
            case ready(Name) of
                true ->
                    ok;
                false ->
                    case remaining(Deadline) of
                        Left when Left > 0 ->
                            timer:sleep(min(Left, 20)),
                            await_ready_loop(Name, Deadline);
                        _ ->
                            {error, timeout}
                    end
            end
    end.

ready(Name) ->
    lists:any(fun({_, _, _, _, _, _, Conns}) -> Conns =/= [] end, rows(Name)).

%%--------------------------------------------------------------------
%% Calls, from `egrpc_stub'

%% @private
unary(Name, Request, Grpc, Opts0) ->
    %% The deadline is the same for every attempt.
    Opts = egrpc_stream:with_deadline(Opts0),
    case retry_config(Name) of
        undefined -> attempt(Name, Request, Grpc, Opts, undefined, [], 1, false, undefined);
        Retry -> attempt(Name, Request, Grpc, Opts, Retry, [], 1, false, undefined)
    end.

%% Only the retry options of the row of the client are copied.
retry_config(Name) ->
    ets:lookup_element(egrpc_index, Name, 6, undefined).

%% One attempt of a unary call. `Excluded' are the targets which failed, `Transparent' is whether
%% the retry for a request which was not sent was used, and `Last' is the error of the attempt
%% before, which is what the call returns when there is no other target to try.
attempt(Name, Request, Grpc, Opts0, Retry, Excluded, N, Transparent, Last) ->
    Opts = case Excluded of
        [] -> Opts0;
        _ -> Opts0#{excluded => Excluded ++ maps:get(excluded, Opts0, [])}
    end,
    case checkout(Name, Opts, true) of
        {ok, Channel, Release, Target} ->
            Result = try
                egrpc_stub:unary(Channel, Request, Grpc, Opts)
            after
                release(Release)
            end,
            after_attempt(Result, Target, Name, Request, Grpc, Opts0, Retry, Excluded, N,
                          Transparent);
        {error, _} = Error when Last =:= undefined ->
            Error;
        {error, _} ->
            %% no other target to try: the error of the call is the one of the target
            Last
    end.

after_attempt({ok, _} = Result, Target, _Name, _Req, _Grpc, _Opts, Retry, _Excluded, _N, _T) ->
    ok = budget_success(Target, Retry),
    Result;
after_attempt({ok, _, _} = Result, Target, _Name, _Req, _Grpc, _Opts, Retry, _Excluded, _N, _T) ->
    ok = budget_success(Target, Retry),
    Result;
after_attempt({error, _} = Error, _Target, _Name, _Req, _Grpc, _Opts, undefined, _Excl, _N, _T) ->
    Error;
after_attempt({error, Reason} = Error, {Id, _, _} = Target,
              Name, Request, Grpc, Opts, Retry, Excluded, N, Transparent) ->
    case egrpc_error:class(Reason) of
        {transport, not_sent} when not Transparent ->
            %% the server did not process it: any method, once, at once
            attempt(Name, Request, Grpc, Opts, Retry, [Id | Excluded], N, true, Error);
        Class ->
            Retryable = Class =:= {transport, unknown} orelse Class =:= {grpc, unavailable},
            case Retryable andalso idempotent(Grpc) andalso N < maps:get(max_attempts, Retry) of
                false ->
                    Error;
                true ->
                    case budget_failure(Target, Retry) andalso wait(N, Retry, Opts) of
                        true ->
                            attempt(Name, Request, Grpc, Opts, Retry, [Id | Excluded], N + 1,
                                    Transparent, Error);
                        false ->
                            Error
                    end
            end
    end.

%% The `Grpc' map is given by the user, so what it lacks is not an error here.
-dialyzer({no_match, idempotent/1}).
idempotent(#{rpc_def := #{opts := Opts}}) when is_list(Opts) ->
    lists:member(proplists:get_value(idempotency_level, Opts, undefined),
                 ['IDEMPOTENT', 'NO_SIDE_EFFECTS']);
idempotent(_) ->
    false.

%% Wait before the attempt after `N': a random time up to the backoff, which does not go past the
%% deadline. `false' when the deadline has passed.
wait(N, #{initial_backoff := Initial, max_backoff := Max, multiplier := Mult}, Opts) ->
    Cap = min(Max, round(Initial * math:pow(Mult, N - 1))),
    Delay = rand:uniform(Cap + 1) - 1,
    case maps:get(deadline_at, Opts, undefined) of
        undefined ->
            timer:sleep(Delay),
            true;
        DeadlineAt ->
            Left = DeadlineAt - erlang:monotonic_time(millisecond),
            case Left > Delay of
                true ->
                    timer:sleep(Delay),
                    true;
                false ->
                    false
            end
    end.

%% The tokens of the retries of a target are in thousandths in its atomics.
budget_success(_Target, undefined) ->
    ok;
budget_success({_Id, Atomics, Size}, #{budget := #{max_tokens := Max, token_ratio := Ratio}}) ->
    Inc = round(Ratio * 1000),
    _ = update(Atomics, 2 * Size + 1, fun(V) -> min(Max * 1000, V + Inc) end),
    ok.

%% Take a token for a failure, and tell whether the target has enough left for a retry.
budget_failure({_Id, Atomics, Size}, #{budget := #{max_tokens := Max}}) ->
    New = update(Atomics, 2 * Size + 1, fun(V) -> max(0, V - 1000) end),
    New > Max * 1000 div 2.

%% Compare and swap loop: concurrent callers do not lose each other's updates. Returns the new value.
update(Atomics, Slot, Fun) ->
    update(Atomics, Slot, Fun, atomics:get(Atomics, Slot)).

update(Atomics, Slot, Fun, Old) ->
    New = Fun(Old),
    case atomics:compare_exchange(Atomics, Slot, Old, New) of
        ok -> New;
        Actual -> update(Atomics, Slot, Fun, Actual)
    end.

%% @private
server_streaming(Name, Request, Grpc, Opts) ->
    case checkout(Name, Opts, false) of
        {ok, Channel, _, _} -> egrpc_stub:server_streaming(Channel, Request, Grpc, Opts);
        {error, _} = Error -> Error
    end.

%% @private
client_streaming(Name, Grpc, Opts) ->
    case checkout(Name, Opts, false) of
        {ok, Channel, _, _} -> egrpc_stub:client_streaming(Channel, Grpc, Opts);
        {error, _} = Error -> Error
    end.

%% @private
bidi_streaming(Name, Grpc, Opts) ->
    case checkout(Name, Opts, false) of
        {ok, Channel, _, _} -> egrpc_stub:bidi_streaming(Channel, Grpc, Opts);
        {error, _} = Error -> Error
    end.

%% Choose a connection for a call. For a unary call (`Count') a place of the connection is
%% reserved in the `atomics' of the target, atomically with the check of the limit, until
%% `release/1'. A stream is not counted.
checkout(Name, Opts, Count) ->
    case ets:lookup(egrpc_index, Name) of
        [{_, Ids, RoundRobin, Template, Balancer, _Retry}] ->
            case pick(Name, Ids, RoundRobin, Balancer, Opts, Count) of
                {ok, Id, Host, Port, Pid, Counters, Idx, Size} ->
                    Release = case Count of
                        true -> {Counters, Idx};
                        false -> undefined
                    end,
                    Ref = {Counters, Idx, Size + Idx},
                    {ok, egrpc_stub:attach(Template, Host, Port, Pid, Ref), Release,
                     {Id, Counters, Size}};
                {error, _} = Error ->
                    Error
            end;
        [] ->
            case ets:member(egrpc_clients, Name) of
                true -> {error, {no_connection_available, no_ready}};
                false -> {error, client_not_found}
            end
    end.

release(undefined) -> ok;
release({Counters, Idx}) -> atomics:sub(Counters, Idx, 1).

pick(_Name, Ids, _RoundRobin, _Balancer, _Opts, _Count) when tuple_size(Ids) =:= 0 ->
    {error, {no_connection_available, no_targets}};
pick(Name, Ids, RoundRobin, {Module, BalancerOpts}, Opts, Count) when is_atom(Module) ->
    Start = atomics:add_get(RoundRobin, 1, 1) - 1,
    Order = egrpc_balancer:order(round_robin, Ids, Start),
    Candidates = [
        #{id => Id, attrs => Attrs, conns => length(Conns)}
        || Id <- Order,
           {Attrs, Conns} <- [candidate(Name, Id, Opts)],
           Conns =/= []
    ],
    case Candidates of
        [] ->
            {error, {no_connection_available, no_ready}};
        _ ->
            case Module:pick(BalancerOpts, Opts, Candidates) of
                {ok, Id} -> choose_target(Name, Id, Count);
                {error, Reason} -> {error, {no_connection_available, Reason}}
            end
    end;
pick(Name, Ids, RoundRobin, Strategy, Opts, Count) ->
    Start = atomics:add_get(RoundRobin, 1, 1) - 1,
    try_targets(egrpc_balancer:order(Strategy, Ids, Start), Name, Opts, false, Count).

try_targets([], _Name, _Opts, true, _Count) ->
    {error, {no_connection_available, no_ready}};
try_targets([], _Name, _Opts, false, _Count) ->
    {error, {no_connection_available, all_excluded}};
try_targets([Id | Ids], Name, Opts, Considered, Count) ->
    case ets:lookup(egrpc_rows, {Name, Id}) of
        [{_, Attrs, Host, Port, Size, Counters, Conns}] ->
            case egrpc_balancer:eligible(Id, Attrs, Opts) of
                false ->
                    try_targets(Ids, Name, Opts, Considered, Count);
                true ->
                    case choose_conn(Counters, Size, Conns, Count) of
                        {Idx, Pid} -> {ok, Id, Host, Port, Pid, Counters, Idx, Size};
                        none -> try_targets(Ids, Name, Opts, true, Count)
                    end
            end;
        [] ->
            %% the pool has not written its row yet, or is being restarted
            try_targets(Ids, Name, Opts, true, Count)
    end.

%% The attrs and the connections which can take a call of a target which may be used for it.
candidate(Name, Id, Opts) ->
    case ets:lookup(egrpc_rows, {Name, Id}) of
        [{_, Attrs, _Host, _Port, Size, Counters, Conns}] ->
            case egrpc_balancer:eligible(Id, Attrs, Opts) of
                true -> {Attrs, [C || C <- Conns, can_take(Counters, Size, C)]};
                false -> {Attrs, []}
            end;
        [] ->
            {#{}, []}
    end.

choose_target(Name, Id, Count) ->
    case ets:lookup(egrpc_rows, {Name, Id}) of
        [{_, _Attrs, Host, Port, Size, Counters, Conns}] ->
            case choose_conn(Counters, Size, Conns, Count) of
                {Idx, Pid} -> {ok, Id, Host, Port, Pid, Counters, Idx, Size};
                none -> {error, {no_connection_available, no_ready}}
            end;
        [] ->
            {error, {no_connection_available, no_ready}}
    end.

%% The connection with the fewest calls in flight of those which are not draining and have not
%% reached the number of concurrent streams of the server. With `Count' the place is reserved:
%% the least busy first, the next one when another caller took the last place meanwhile.
choose_conn(Counters, Size, Conns, true) ->
    case choose_conn(Counters, Size, Conns, none, infinity) of
        none ->
            none;
        {Idx, _Pid} = Best ->
            {_, _, Max} = lists:keyfind(Idx, 1, Conns),
            case reserve(Counters, Idx, Max) of
                true -> Best;
                false -> reserve_first(Counters, Size, Conns, Idx)
            end
    end;
choose_conn(Counters, Size, Conns, false) ->
    choose_conn(Counters, Size, Conns, none, infinity).

%% The least busy connection was taken meanwhile: the others, the least busy first.
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

choose_conn(_Counters, _Size, [], Best, _BestInflight) ->
    Best;
choose_conn(Counters, Size, [{Idx, Pid, _Max} = C | Rest], Best, BestInflight) ->
    case can_take(Counters, Size, C) of
        false ->
            choose_conn(Counters, Size, Rest, Best, BestInflight);
        true ->
            Inflight = atomics:get(Counters, Idx),
            case Inflight < BestInflight of
                true -> choose_conn(Counters, Size, Rest, {Idx, Pid}, Inflight);
                false -> choose_conn(Counters, Size, Rest, Best, BestInflight)
            end
    end.

can_take(Counters, Size, {Idx, _Pid, Max}) ->
    atomics:get(Counters, Size + Idx) =:= 0 andalso
        (Max =:= infinity orelse atomics:get(Counters, Idx) < Max).

%%--------------------------------------------------------------------
%% The process of the client

-record(state, {
    name :: egrpc:client_name(),
    pool_sup :: undefined | pid(),
    targets = #{} :: #{term() => target()},
    atomics :: atomics:atomics_ref(),
    %% What a call needs of the client besides its targets, in its row of `egrpc_index': the
    %% channel which has the pipeline, the balancer, and the retry options.
    config :: egrpc_registry:config()
}).

%% @private
start_link(Name) ->
    gen_server:start_link(?MODULE, Name, []).

%% @private
init(Name) ->
    {ok, {_, Opts, _, _, _}} = egrpc_registry:lookup(Name),
    ConnOpts = maps:get(conn_opts, Opts),
    Template = egrpc_stub:client_channel(ConnOpts),
    Retry = case maps:get(retry, Opts, undefined) of
        undefined -> undefined;
        RetryOpts -> RetryOpts#{budget => maps:get(retry_budget, Opts)}
    end,
    ok = egrpc_registry:set_client(Name, self()),
    State = #state{
        name = Name,
        atomics = atomics:new(1, []),
        config = {Template, maps:get(balancer, Opts), Retry}
    },
    {ok, State, {continue, init_pools}}.

%% @private
handle_continue(init_pools, State) ->
    %% the supervisor knows its children once it has started them
    PoolSup = pool_sup(),
    {noreply, reload(State#state{pool_sup = PoolSup})}.

%% @private
handle_call(reload, _From, State) ->
    {reply, ok, reload(State)};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info(_Info, State) ->
    {noreply, State}.

pool_sup() ->
    %% the supervisor of this process
    [Parent | _] = get('$ancestors'),
    Sup = case is_pid(Parent) of
        true -> Parent;
        false -> whereis(Parent)
    end,
    {_, Pid, _, _} = lists:keyfind(pool_sup, 1, supervisor:which_children(Sup)),
    Pid.

%% Make the pools the ones of the targets in the registry.
reload(#state{name = Name, pool_sup = PoolSup, targets = Old, atomics = Atomics,
               config = Config} = State) ->
    case egrpc_registry:lookup(Name) of
        not_found ->
            State;
        {ok, {_, Opts, List, _, _}} ->
            New = maps:from_list([{Id, T} || #{id := Id} = T <- List]),
            ok = apply_targets(Name, Opts, PoolSup, Old, New),
            ok = egrpc_registry:set_index(Name, [Id || #{id := Id} <- List], Atomics, Config),
            State#state{targets = New}
    end.

apply_targets(Name, Opts, PoolSup, Old, New) ->
    maps:foreach(
        fun(Id, _) ->
            case maps:is_key(Id, New) of
                true -> ok;
                false -> stop_pool(PoolSup, Id)
            end
        end,
        Old
    ),
    maps:foreach(
        fun(Id, #{host := Host, port := Port} = Target) ->
            case maps:find(Id, Old) of
                error ->
                    start_pool(Name, Opts, PoolSup, Target);
                {ok, Target} ->
                    ok;
                {ok, #{host := Host, port := Port}} ->
                    %% the attrs only
                    cast_attrs(PoolSup, Id, maps:get(attrs, Target, #{}));
                {ok, _} ->
                    ok = stop_pool(PoolSup, Id),
                    start_pool(Name, Opts, PoolSup, Target)
            end
        end,
        New
    ).

start_pool(Name, Opts, PoolSup, #{id := Id} = Target) ->
    ConnOpts = maps:get(conn_opts, Opts),
    Args = #{
        name => Name,
        target => Target,
        pool_size => maps:get(pool_size, Opts),
        gun_opts => egrpc_stub:gun_opts(ConnOpts),
        reconnect_backoff => maps:get(reconnect_backoff, Opts),
        retry_budget => case maps:is_key(retry, Opts) of
            true -> maps:get(retry_budget, Opts);
            false -> undefined
        end
    },
    Spec = #{
        id => Id,
        start => {egrpc_pool, start_link, [Args]},
        restart => transient,
        shutdown => 10000
    },
    case supervisor:start_child(PoolSup, Spec) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, already_present} ->
            _ = supervisor:delete_child(PoolSup, Id),
            start_pool(Name, Opts, PoolSup, Target)
    end.

stop_pool(PoolSup, Id) ->
    _ = supervisor:terminate_child(PoolSup, Id),
    _ = supervisor:delete_child(PoolSup, Id),
    ok.

cast_attrs(PoolSup, Id, Attrs) ->
    case lists:keyfind(Id, 1, supervisor:which_children(PoolSup)) of
        {_, Pid, _, _} when is_pid(Pid) -> gen_server:cast(Pid, {attrs, Attrs});
        _ -> ok
    end.

%%--------------------------------------------------------------------
%% Helpers

%% The rows of the targets of the client.
rows(Name) ->
    case ets:lookup(egrpc_index, Name) of
        [{_, Ids, _, _, _, _}] ->
            lists:append([ets:lookup(egrpc_rows, {Name, Id}) || Id <- tuple_to_list(Ids)]);
        [] ->
            []
    end.

deadline(infinity) -> infinity;
deadline(Timeout) -> erlang:monotonic_time(millisecond) + Timeout.

remaining(infinity) -> infinity;
remaining(Deadline) -> Deadline - erlang:monotonic_time(millisecond).

%% Wait until no unary call is in flight, or until the deadline.
wait_drained(Counters, Deadline) ->
    InFlight = lists:sum([
        atomics:get(C, Idx) || {C, Size} <- Counters, Idx <- lists:seq(1, Size)
    ]),
    case InFlight of
        0 ->
            ok;
        _ ->
            case remaining(Deadline) of
                Left when Left =:= infinity; Left > 0 ->
                    timer:sleep(20),
                    wait_drained(Counters, Deadline);
                _ ->
                    ok
            end
    end.

%% The options of `start/2' with the defaults, an option which is not valid raises an error.
validate(Opts) ->
    case [K || K <- maps:keys(Opts), not lists:member(K, ?START_OPTS)] of
        [] -> ok;
        [Key | _] -> error({invalid_option, Key})
    end,
    PoolSize = maps:get(pool_size, Opts, ?DEFAULT_POOL_SIZE),
    (is_integer(PoolSize) andalso PoolSize > 0) orelse error({invalid_option, {pool_size, PoolSize}}),
    Balancer = case maps:get(balancer, Opts, round_robin) of
        pick_first -> pick_first;
        round_robin -> round_robin;
        {Mod, _} = B when is_atom(Mod) -> B;
        Other -> error({invalid_option, {balancer, Other}})
    end,
    Backoff = maps:merge(egrpc_pool:default_backoff(), maps:get(reconnect_backoff, Opts, #{})),
    Config = #{
        targets => validate_targets(maps:get(targets, Opts, [])),
        pool_size => PoolSize,
        balancer => Balancer,
        reconnect_backoff => Backoff,
        conn_opts => maps:get(conn_opts, Opts, #{})
    },
    case maps:find(retry, Opts) of
        {ok, Retry} when is_map(Retry) ->
            Config#{
                retry => maps:merge(
                    #{max_attempts => 3, initial_backoff => 50, max_backoff => 1000, multiplier => 2},
                    Retry
                ),
                retry_budget => maps:merge(
                    #{max_tokens => 100, token_ratio => 0.1},
                    maps:get(retry_budget, Opts, #{})
                )
            };
        {ok, NotAMap} ->
            error({invalid_option, {retry, NotAMap}});
        error ->
            Config
    end.

validate_targets(Targets) when is_list(Targets) ->
    Valid = [validate_target(T) || T <- Targets],
    Ids = [Id || #{id := Id} <- Valid],
    length(Ids) =:= length(lists:usort(Ids)) orelse error({invalid_option, {targets, duplicate_id}}),
    Valid;
validate_targets(Other) ->
    error({invalid_option, {targets, Other}}).

validate_target(#{id := _, host := Host, port := Port} = Target) when is_integer(Port) ->
    Host1 = case Host of
        _ when is_list(Host) -> Host;
        _ when is_binary(Host) -> binary_to_list(Host);
        _ -> error({invalid_target, Target})
    end,
    Target#{host := Host1};
validate_target(Other) ->
    error({invalid_target, Other}).

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
         Results = concurrently(8, fun() -> choose_conn(A, 1, Conns, true) end),
         ?assertEqual(Max, length([R || R <- Results, R =/= none])),
         ?assertEqual(Max, atomics:get(A, 1))
     end || _ <- lists:seq(1, ?ROUNDS)],
    ok.

reserve_falls_over_to_the_next_connection_test() ->
    Conns = [{1, c1, 1}, {2, c2, 1}],
    [begin
         A = atomics:new(5, [{signed, true}]),
         Results = concurrently(8, fun() -> choose_conn(A, 2, Conns, true) end),
         Got = [R || R <- Results, R =/= none],
         ?assertEqual(2, length(Got)),
         ?assertEqual([1, 1], [atomics:get(A, 1), atomics:get(A, 2)])
     end || _ <- lists:seq(1, ?ROUNDS)],
    ok.

reserve_skips_a_draining_connection_test() ->
    A = atomics:new(3, [{signed, true}]),
    ok = atomics:put(A, 2 + 1, 1),
    ?assertEqual(none, choose_conn(A, 2, [{1, c1, infinity}], true)),
    ?assertEqual(0, atomics:get(A, 1)).

reserve_without_a_limit_counts_test() ->
    A = atomics:new(3, [{signed, true}]),
    Results = concurrently(50, fun() -> choose_conn(A, 1, [{1, c, infinity}], true) end),
    ?assertEqual(50, length([R || R <- Results, R =/= none])),
    ?assertEqual(50, atomics:get(A, 1)).

budget_does_not_lose_updates_test() ->
    Retry = #{budget => #{max_tokens => 1000, token_ratio => 1.0}},
    [begin
         A = atomics:new(3, [{signed, true}]),
         Target = {id, A, 1},
         ok = atomics:put(A, 3, 1000 * 1000),
         concurrently(8, fun() -> budget_failure(Target, Retry) end),
         ?assertEqual(1000 * 1000 - 8 * 1000, atomics:get(A, 3)),
         concurrently(8, fun() -> budget_success(Target, Retry) end),
         ?assertEqual(1000 * 1000 - 8 * 1000 + 8 * 1000, atomics:get(A, 3))
     end || _ <- lists:seq(1, ?ROUNDS)],
    ok.

budget_stays_within_bounds_test() ->
    A = atomics:new(3, [{signed, true}]),
    Target = {id, A, 1},
    Retry = #{budget => #{max_tokens => 10, token_ratio => 0.5}},
    ok = atomics:put(A, 3, 10 * 1000),
    concurrently(100, fun() -> budget_success(Target, Retry) end),
    ?assertEqual(10 * 1000, atomics:get(A, 3)),
    concurrently(20, fun() -> budget_failure(Target, Retry) end),
    ?assertEqual(0, atomics:get(A, 3)).
-endif.
