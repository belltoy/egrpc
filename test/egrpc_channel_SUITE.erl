%% @doc Channels: the endpoints, the subchannels and their transports, reconnects, the choice of
%% an endpoint, the retries, with real connections to the fake server.
-module(egrpc_channel_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    start_is_async/1,
    already_started/1,
    invalid_options/1,
    no_endpoints/1,
    unavailable_at_once/1,
    wait_for_ready/1,
    wait_for_ready_deadline/1,
    dns_resolver/1,
    round_robin/1,
    pick_first_and_failover/1,
    update_endpoints/1,
    reconnects/1,
    transport_pool_min/1,
    transport_pool_scale_up/1,
    transport_pool_scale_down/1,
    full_transport_fails_fast/1,
    stop_waits_for_calls/1,
    survives_a_crashed_coordinator/1,
    derive/1,
    retry_not_sent/1,
    no_retry_without_idempotency/1,
    retry_idempotent/1,
    retry_budget/1,
    retry_max_attempts/1,
    retry_off_for_a_call/1,
    attempt_hooks_of_a_retry/1
]).

-define(NAME, egrpc_channel_SUITE_channel).
-define(CHECK(Client), egrpc_grpc_health_v1_health_stub:check(Client, #{service => <<"s">>})).
-define(CHECK(Client, Opts),
        egrpc_grpc_health_v1_health_stub:check(Client, #{service => <<"s">>}, Opts)).

all() ->
    [
        start_is_async,
        already_started,
        invalid_options,
        no_endpoints,
        unavailable_at_once,
        wait_for_ready,
        wait_for_ready_deadline,
        dns_resolver,
        round_robin,
        pick_first_and_failover,
        update_endpoints,
        reconnects,
        transport_pool_min,
        transport_pool_scale_up,
        transport_pool_scale_down,
        full_transport_fails_fast,
        stop_waits_for_calls,
        survives_a_crashed_coordinator,
        derive,
        retry_not_sent,
        no_retry_without_idempotency,
        retry_idempotent,
        retry_budget,
        retry_max_attempts,
        retry_off_for_a_call,
        attempt_hooks_of_a_retry
    ].

init_per_suite(Config) ->
    ok = egrpc_test_util:start_apps(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    ct:timetrap({seconds, 40}),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = egrpc_channel:stop(?NAME, 1000),
    ok.

%% A server which answers every call, and tells the test process `{hit, Tag}'.
serve(Tag) ->
    serve(Tag, #{}).

serve(Tag, Extra) ->
    Self = self(),
    {ok, Ref} = egrpc_fake_server:start(
        fun(_Request) ->
            Self ! {hit, Tag},
            egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING'))
        end,
        Extra
    ),
    Ref.

%% The target of the servers: `static:///' and `localhost' with the ports.
target(Servers) ->
    "static:///" ++ lists:join(",", [egrpc_test_util:target(egrpc_fake_server:port(S)) || S <- Servers]).

start(Servers) ->
    start(Servers, #{}).

start(Servers, Opts) ->
    start_target(target(Servers), Opts).

start_target(Target, Opts) ->
    ok = egrpc_channel:start(?NAME, Opts#{
        target => Target,
        reconnect_backoff => #{initial => 50, max => 200, multiplier => 2, jitter => 0}
    }).

hits() ->
    receive
        {hit, Tag} -> [Tag | hits()]
    after 100 -> []
    end.

stop_servers(Servers) ->
    [egrpc_fake_server:stop(S) || S <- Servers],
    ok.

%%--------------------------------------------------------------------

%% `start/2' returns before the connections are up, `await_ready/2' waits for them.
start_is_async(_Config) ->
    Srv = serve(a),
    start([Srv]),
    ?assertEqual(ok, egrpc_channel:await_ready(?NAME, 5000)),
    ?assertEqual({ok, #{status => 'SERVING'}}, ?CHECK(?NAME)),
    ?assertEqual(ready, egrpc_channel:connectivity(?NAME)),
    ?assertMatch(#{connectivity := ready, subchannels := [#{state := ready}]},
                 egrpc_channel:describe(?NAME)),
    ?assertEqual(ok, egrpc_channel:stop(?NAME)),
    %% the opposite of start
    ?assertEqual({error, channel_not_found}, ?CHECK(?NAME)),
    ?assertEqual({error, channel_not_found}, egrpc_channel:stop(?NAME)),
    ?assertEqual({error, channel_not_found}, egrpc_channel:await_ready(?NAME, 100)),
    stop_servers([Srv]).

already_started(_Config) ->
    Srv = serve(a),
    start([Srv]),
    ?assertMatch({error, {already_started, _}},
                 egrpc_channel:start(?NAME, #{target => "localhost:1"})),
    stop_servers([Srv]).

invalid_options(_Config) ->
    % eqwalizer:ignore
    ?assertError({missing_option, target}, egrpc_channel:start(nope, #{})),
    % eqwalizer:ignore
    ?assertError({invalid_option, foo}, egrpc_channel:start(nope, #{target => "h:1", foo => 1})),
    ?assertError({invalid_target, _}, egrpc_channel:start(nope, #{target => "xds:///h:1"})),
    ?assertError({invalid_address, _}, egrpc_channel:start(nope, #{target => "static:///h"})),
    ?assertError({invalid_option, {min_connections, 0}},
                 egrpc_channel:start(nope, #{target => "h:1", transport_pool => #{min_connections => 0}})),
    ?assertError({invalid_option, {balancer, 1}},
                 % eqwalizer:ignore
                 egrpc_channel:start(nope, #{target => "h:1", balancer => 1})),
    ?assertError({invalid_option, {retry, foo}},
                 egrpc_channel:start(nope, #{target => "h:1", retry => #{foo => 1}})).

no_endpoints(_Config) ->
    ok = egrpc_channel:start(?NAME, #{target => "static:///"}),
    ?assertMatch({error, {grpc_error, unavailable, _}}, ?CHECK(?NAME)),
    ?assertEqual({error, timeout}, egrpc_channel:await_ready(?NAME, 100)).

%% An endpoint which can not be reached: the call does not wait, the channel keeps trying.
unavailable_at_once(_Config) ->
    Srv = serve(a),
    Port = egrpc_fake_server:port(Srv),
    ok = egrpc_fake_server:stop(Srv),
    start_target(egrpc_test_util:target(Port), #{}),
    T0 = erlang:monotonic_time(millisecond),
    ?assertMatch({error, {grpc_error, unavailable, _}}, ?CHECK(?NAME)),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 500),
    ?assertEqual({error, timeout}, egrpc_channel:await_ready(?NAME, 300)),
    %% still there after the timeout
    ?assertEqual(transient_failure, wait_connectivity(transient_failure)),
    ?assertMatch({error, {grpc_error, unavailable, _}}, ?CHECK(?NAME)).

%% A call which waits for ready gets the answer when the server comes up.
wait_for_ready(_Config) ->
    Srv = serve(a),
    Port = egrpc_fake_server:port(Srv),
    ok = egrpc_fake_server:stop(Srv),
    start_target(egrpc_test_util:target(Port), #{}),
    Self = self(),
    spawn_link(fun() -> Self ! {result, ?CHECK(?NAME, #{wait_for_ready => true, deadline => 10000})} end),
    timer:sleep(500),
    receive {result, R} -> ct:fail({returned_early, R}) after 0 -> ok end,
    {ok, Srv2} = egrpc_fake_server:start(
        fun(_) -> egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING')) end,
        #{listen_port => Port}
    ),
    receive
        {result, Result} -> ?assertEqual({ok, #{status => 'SERVING'}}, Result)
    after 8000 -> ct:fail(no_result)
    end,
    stop_servers([Srv2]).

wait_for_ready_deadline(_Config) ->
    Srv = serve(a),
    Port = egrpc_fake_server:port(Srv),
    ok = egrpc_fake_server:stop(Srv),
    start_target(egrpc_test_util:target(Port), #{}),
    T0 = erlang:monotonic_time(millisecond),
    ?assertMatch({error, {grpc_error, deadline_exceeded, _}},
                 ?CHECK(?NAME, #{wait_for_ready => true, deadline => 400})),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ?assert(Elapsed >= 350),
    ?assert(Elapsed < 1500).

dns_resolver(_Config) ->
    Srv = serve(a),
    ok = egrpc_channel:start(?NAME, #{
        target => "dns:///localhost:" ++ integer_to_list(egrpc_fake_server:port(Srv))
    }),
    ?assertEqual(ok, egrpc_channel:await_ready(?NAME, 5000)),
    ?assertEqual({ok, #{status => 'SERVING'}}, ?CHECK(?NAME)),
    stop_servers([Srv]).

round_robin(_Config) ->
    A = serve(a),
    B = serve(b),
    start([A, B]),
    ok = wait_ready(2),
    [?assertMatch({ok, _}, ?CHECK(?NAME)) || _ <- lists:seq(1, 6)],
    ?assertEqual([a, a, a, b, b, b], lists:sort(hits())),
    stop_servers([A, B]).

%% One subchannel at first, the next one when the first fails, the first one again when it is back.
pick_first_and_failover(_Config) ->
    A = serve(a),
    B = serve(b),
    start([A, B], #{balancer => pick_first}),
    ok = wait_ready(1),
    [?assertMatch({ok, _}, ?CHECK(?NAME)) || _ <- lists:seq(1, 4)],
    ?assertEqual([a, a, a, a], hits()),
    ?assertMatch(#{subchannels := [_]}, egrpc_channel:describe(?NAME)),
    Port = egrpc_fake_server:port(A),
    ok = egrpc_fake_server:stop(A),
    ok = wait_until(fun() -> match({ok, #{status => 'SERVING'}}, ?CHECK(?NAME)) end, 10000),
    ?assertEqual([b], lists:usort(hits())),
    {ok, A2} = egrpc_fake_server:start(
        fun(_) -> egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING')) end,
        #{listen_port => Port}
    ),
    stop_servers([A2, B]).

update_endpoints(_Config) ->
    A = serve(a),
    B = serve(b),
    start([A]),
    ok = wait_ready(1),
    ?assertMatch({ok, _}, ?CHECK(?NAME)),
    ?assertEqual([a], hits()),
    %% an endpoint is added
    ok = egrpc_channel:update_endpoints(?NAME, [egrpc_test_util:target(egrpc_fake_server:port(S)) || S <- [A, B]]),
    ok = wait_ready(2),
    [?assertMatch({ok, _}, ?CHECK(?NAME)) || _ <- lists:seq(1, 4)],
    ?assertEqual([a, a, b, b], lists:sort(hits())),
    %% an endpoint which is kept is not touched
    Conns = ranch:procs(A, connections),
    ok = egrpc_channel:update_endpoints(?NAME, [egrpc_test_util:target(egrpc_fake_server:port(B)),
                                                egrpc_test_util:target(egrpc_fake_server:port(A))]),
    timer:sleep(200),
    ?assertEqual(Conns, ranch:procs(A, connections)),
    %% an endpoint is removed, its connections are closed
    ok = egrpc_channel:update_endpoints(?NAME, [egrpc_test_util:target(egrpc_fake_server:port(B))]),
    ok = wait_until(fun() -> ranch:procs(A, connections) =:= [] end, 5000),
    ?assertMatch({ok, _}, ?CHECK(?NAME)),
    ?assertEqual([b], hits()),
    ?assertMatch({error, _}, egrpc_channel:update_endpoints(no_such_channel, [])),
    stop_servers([A, B]).

%% The connections which the server closed are made again.
reconnects(_Config) ->
    Srv = serve(a),
    start([Srv], #{transport_pool => #{min_connections => 2}}),
    ?assertEqual(ok, egrpc_channel:await_ready(?NAME, 5000)),
    ok = wait_until(fun() -> length(ranch:procs(Srv, connections)) =:= 2 end, 5000),
    Old = ranch:procs(Srv, connections),
    [exit(P, kill) || P <- Old],
    ok = wait_until(
        fun() ->
            New = ranch:procs(Srv, connections),
            length(New) =:= 2 andalso New -- Old =:= New
        end,
        10000
    ),
    ok = wait_until(fun() -> match({ok, #{status => 'SERVING'}}, ?CHECK(?NAME)) end, 5000),
    stop_servers([Srv]).

%% The server sees `min_connections' connections for an endpoint, and no more.
transport_pool_min(_Config) ->
    Srv = serve(a),
    start([Srv], #{transport_pool => #{min_connections => 3, max_connections => 4}}),
    ?assertEqual(ok, egrpc_channel:await_ready(?NAME, 5000)),
    ok = wait_until(fun() -> length(ranch:procs(Srv, connections)) =:= 3 end, 5000),
    [?assertMatch({ok, _}, ?CHECK(?NAME)) || _ <- lists:seq(1, 10)],
    timer:sleep(200),
    ?assertEqual(3, length(ranch:procs(Srv, connections))),
    stop_servers([Srv]).

%% The server takes one concurrent stream: a call which waits for ready is given the connection
%% which the saturation of the first one makes.
transport_pool_scale_up(_Config) ->
    {ok, Srv} = egrpc_fake_server:start(
        fun(_) -> [{sleep, 800} | egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING'))] end,
        #{max_concurrent_streams => 1}
    ),
    start([Srv], #{transport_pool => #{min_connections => 1, max_connections => 2}}),
    ok = wait_ready(1),
    ok = wait_until(fun() -> length(ranch:procs(Srv, connections)) =:= 1 end, 5000),
    Self = self(),
    [spawn_link(fun() -> Self ! {result, ?CHECK(?NAME, #{wait_for_ready => true})} end)
     || _ <- lists:seq(1, 2)],
    Results = [receive {result, R} -> R after 8000 -> timeout end || _ <- lists:seq(1, 2)],
    ?assertEqual([{ok, #{status => 'SERVING'}}, {ok, #{status => 'SERVING'}}], Results),
    ?assertEqual(2, length(ranch:procs(Srv, connections))),
    stop_servers([Srv]).

%% The transports above `min_connections' which are not used are closed.
transport_pool_scale_down(_Config) ->
    {ok, Srv} = egrpc_fake_server:start(
        fun(_) -> [{sleep, 500} | egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING'))] end,
        #{max_concurrent_streams => 1}
    ),
    start([Srv], #{transport_pool => #{min_connections => 1, max_connections => 2,
                                       idle_timeout => 300}}),
    ok = wait_ready(1),
    Self = self(),
    [spawn_link(fun() -> Self ! {result, ?CHECK(?NAME, #{wait_for_ready => true})} end)
     || _ <- lists:seq(1, 2)],
    [receive {result, {ok, _}} -> ok after 8000 -> ct:fail(no_result) end || _ <- lists:seq(1, 2)],
    ok = wait_until(fun() -> length(ranch:procs(Srv, connections)) =:= 2 end, 5000),
    ok = wait_until(fun() -> length(ranch:procs(Srv, connections)) =:= 1 end, 10000),
    %% and the endpoint still works
    ?assertMatch({ok, _}, ?CHECK(?NAME)),
    stop_servers([Srv]).

%% A transport which has as many calls in flight as the server allows is not used, a call which
%% does not wait for ready does not wait for it.
full_transport_fails_fast(_Config) ->
    {ok, Srv} = egrpc_fake_server:start(
        fun(_) -> [{sleep, 800} | egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING'))] end,
        #{max_concurrent_streams => 1}
    ),
    start([Srv]),
    ok = wait_ready(1),
    Self = self(),
    spawn_link(fun() -> Self ! {result, ?CHECK(?NAME)} end),
    timer:sleep(300),
    ?assertMatch({error, {grpc_error, unavailable, _}}, ?CHECK(?NAME)),
    receive
        {result, Result} -> ?assertEqual({ok, #{status => 'SERVING'}}, Result)
    after 3000 -> ct:fail(no_result)
    end,
    ?assertMatch({ok, _}, ?CHECK(?NAME)),
    stop_servers([Srv]).

%% The unary calls which are in flight return before the connections are closed.
stop_waits_for_calls(_Config) ->
    {ok, Srv} = egrpc_fake_server:start(fun(_) ->
        [{sleep, 600} | egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING'))]
    end),
    start([Srv]),
    ok = wait_ready(1),
    Self = self(),
    spawn_link(fun() -> Self ! {result, ?CHECK(?NAME)} end),
    timer:sleep(200),
    ?assertEqual(ok, egrpc_channel:stop(?NAME, 5000)),
    receive
        {result, Result} -> ?assertEqual({ok, #{status => 'SERVING'}}, Result)
    after 0 -> ct:fail(stopped_before_the_call_returned)
    end,
    ?assertEqual({error, channel_not_found}, ?CHECK(?NAME)),
    stop_servers([Srv]).

%% The coordinator crashes: its supervisor starts it with the resolver and the subchannels again,
%% from the options in the registry.
survives_a_crashed_coordinator(_Config) ->
    Srv = serve(a),
    start([Srv]),
    ok = wait_ready(1),
    Pid = case egrpc_registry:lookup(?NAME) of {ok, {_, _, _, C}} when is_pid(C) -> C end,
    MRef = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', MRef, process, Pid, _} -> ok after 2000 -> ct:fail(not_killed) end,
    ok = wait_until(
        fun() ->
            case egrpc_registry:lookup(?NAME) of
                {ok, {_, _, _, P}} -> is_pid(P) andalso P =/= Pid;
                _ -> false
            end
        end,
        5000
    ),
    ?assertEqual(ok, egrpc_channel:await_ready(?NAME, 5000)),
    ?assertMatch({ok, _}, ?CHECK(?NAME)),
    stop_servers([Srv]).

derive(_Config) ->
    Srv = serve(a),
    start([Srv], #{info => original}),
    ok = wait_ready(1),
    D = egrpc_channel:derive(?NAME, #{info => derived}),
    ?assertEqual(original, egrpc_channel:info(?NAME)),
    ?assertEqual(derived, egrpc_channel:info(D)),
    ?assertEqual(derived, egrpc_channel:info(egrpc_channel:derive(D, #{wait_for_ready => true}))),
    %% the same subchannels
    ?assertMatch({ok, _}, ?CHECK(D)),
    ?assertEqual([a], hits()),
    % eqwalizer:ignore
    ?assertError({invalid_option, gun_opts}, egrpc_channel:derive(?NAME, #{gun_opts => #{}})),
    % eqwalizer:ignore
    ?assertError({invalid_option, retry}, egrpc_channel:derive(D, #{retry => #{}})),
    %% a derived channel of a channel which is stopped
    ok = egrpc_channel:stop(?NAME, 1000),
    ?assertEqual({error, channel_not_found}, ?CHECK(D)),
    stop_servers([Srv]).

%% A connection which got `GOAWAY' refuses the next call, which is made again on another endpoint
%% for any method, and the connection is skipped after it.
retry_not_sent(_Config) ->
    Counter = atomics:new(1, []),
    Self = self(),
    {ok, A} = egrpc_fake_server:start(fun(_) ->
        Self ! {hit, a},
        case atomics:add_get(Counter, 1, 1) of
            1 -> [{sleep, 1500} | ok_actions()];
            _ -> ok_actions()
        end
    end),
    B = serve(b),
    start([A, B], #{balancer => pick_first, retry => #{}}),
    %% pick_first has a subchannel for `a' only, until it fails
    ok = wait_ready(1),
    Slow = spawn_call(),
    timer:sleep(300),
    [ConnPid] = ranch:procs(A, connections),
    %% the connection process dies of it, the caller of terminate gets the exit
    spawn(fun() ->
        try sys:terminate(ConnPid, shutdown)
        catch exit:_ -> ok
        end
    end),
    timer:sleep(300),
    ?assertEqual([a], hits()),
    %% refused by gun, the server of `a' did not see it
    ?assertMatch({error, _}, ?CHECK(?NAME)),
    ?assertEqual([], hits()),
    ?assertMatch({ok, _}, receive_call(Slow)),
    stop_servers([A, B]).

%% The request may have been processed, a method which is not idempotent is not made again.
no_retry_without_idempotency(_Config) ->
    A = unavailable(a),
    B = serve(b),
    start([A, B], #{retry => #{}}),
    ok = wait_ready(2),
    ?assertMatch({error, {grpc_error, unavailable, _}}, ?CHECK(?NAME)),
    ?assertEqual([a], hits()),
    stop_servers([A, B]).

%% It goes to another endpoint: the first one is avoided.
retry_idempotent(_Config) ->
    A = unavailable(a),
    B = serve(b),
    start([A, B], #{retry => #{}}),
    ok = wait_ready(2),
    ?assertMatch({ok, _}, idempotent_check(?NAME)),
    ?assertEqual([a, b], hits()),
    stop_servers([A, B]).

%% Every failure takes a token, no retry is made when the channel has half of them or fewer.
retry_budget(_Config) ->
    A = unavailable(a),
    B = serve(b),
    %% the rotation goes to `a' first, then to `b' for the retry, and so on
    start([A, B], #{retry => #{}, retry_budget => #{max_tokens => 4, token_ratio => 0.1}}),
    ok = wait_ready(2),
    %% 4 tokens, 3 after the failure: a retry, which gives a tenth back
    ?assertMatch({ok, _}, idempotent_check(?NAME)),
    ?assertEqual([a, b], hits()),
    %% 3.1, 2.1 after the failure: above half of them, a retry
    ?assertMatch({ok, _}, idempotent_check(?NAME)),
    ?assertEqual([a, b], hits()),
    %% 2.2, 1.2 after the failure: not above half of them
    ?assertMatch({error, {grpc_error, unavailable, _}}, idempotent_check(?NAME)),
    ?assertEqual([a], hits()),
    stop_servers([A, B]).

retry_max_attempts(_Config) ->
    Servers = [unavailable(a), unavailable(b), unavailable(c)],
    start(Servers, #{retry => #{max_attempts => 2}}),
    ok = wait_ready(3),
    ?assertMatch({error, {grpc_error, unavailable, _}}, idempotent_check(?NAME)),
    ?assertEqual([a, b], hits()),
    stop_servers(Servers).

retry_off_for_a_call(_Config) ->
    A = unavailable(a),
    B = serve(b),
    start([A, B], #{retry => #{}}),
    ok = wait_ready(2),
    ?assertMatch({error, {grpc_error, unavailable, _}}, idempotent_check(?NAME, #{retry => false})),
    ?assertEqual([a], hits()),
    %% the rotation is at `b', which answers
    ?assertMatch({ok, _}, idempotent_check(?NAME, #{retry => false})),
    ?assertEqual([b], hits()),
    %% the keys of the policy which are given are changed for the call
    ?assertMatch({error, {grpc_error, unavailable, _}},
                 idempotent_check(?NAME, #{retry => #{max_attempts => 1}})),
    ?assertEqual([a], hits()),
    stop_servers([A, B]).

%% Every attempt is told to the hooks, with its number.
attempt_hooks_of_a_retry(_Config) ->
    A = unavailable(a),
    B = serve(b),
    start([A, B], #{retry => #{}, attempt_hooks => [egrpc_test_recorder]}),
    ok = wait_ready(2),
    ?assertMatch({ok, _}, idempotent_check(?NAME)),
    ?assertEqual([a, b], hits()),
    Events = receive_events(),
    ?assertEqual(
        [{attempt_start, 0}, {attempt_end, {0, error}}, {attempt_start, 1}, {attempt_end, {1, ok}}],
        Events
    ),
    stop_servers([A, B]).

%%--------------------------------------------------------------------

receive_events() ->
    receive
        {event, a, Hook, Detail} -> [{Hook, Detail} | receive_events()]
    after 100 -> []
    end.

ok_actions() ->
    egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING')).

%% A server which answers `unavailable' to every call.
unavailable(Tag) ->
    Self = self(),
    {ok, Ref} = egrpc_fake_server:start(fun(_) ->
        Self ! {hit, Tag},
        egrpc_fake_server:status(14, <<"unavailable">>)
    end),
    Ref.

%% The health check as a method which is marked idempotent.
idempotent_check(Client) ->
    idempotent_check(Client, #{}).

idempotent_check(Client, Opts) ->
    RpcDef0 = egrpc_health_pb:find_rpc_def('grpc.health.v1.Health', 'Check'),
    RpcDef = RpcDef0#{opts => [{idempotency_level, 'IDEMPOTENT'}]},
    Grpc = #{
        rpc_def => RpcDef,
        path => <<"/grpc.health.v1.Health/Check">>,
        pb_module => egrpc_health_pb,
        service_name => 'grpc.health.v1.Health'
    },
    egrpc_client:unary(Client, #{service => <<"s">>}, Grpc, Opts).

spawn_call() ->
    Self = self(),
    Ref = make_ref(),
    spawn_link(fun() -> Self ! {Ref, ?CHECK(?NAME)} end),
    Ref.

receive_call(Ref) ->
    receive {Ref, Result} -> Result after 5000 -> ct:fail(no_result) end.

match(Expected, Expected) -> true;
match(_, _) -> false.

%% At least `N' subchannels of the channel are ready.
wait_ready(N) ->
    wait_until(
        fun() ->
            #{subchannels := Subs} = egrpc_channel:describe(?NAME),
            length([S || #{state := ready} = S <- Subs]) >= N
        end,
        5000
    ).

wait_connectivity(State) ->
    ok = wait_until(fun() -> egrpc_channel:connectivity(?NAME) =:= State end, 5000),
    State.

wait_until(Fun, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_until_loop(Fun, Deadline).

wait_until_loop(Fun, Deadline) ->
    case Fun() of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    ct:fail(wait_until_timeout);
                false ->
                    timer:sleep(25),
                    wait_until_loop(Fun, Deadline)
            end
    end.
