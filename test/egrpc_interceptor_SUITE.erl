%% @doc The interceptors, the stream hooks and the attempt hooks against the fake server.
-module(egrpc_interceptor_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    unary_wraps_order/1,
    unary_does_not_fire_stream_hooks/1,
    unary_wrap_can_call_next_again/1,
    unary_wrap_changes_result/1,
    fun_wraps_unary_only/1,
    streaming_hooks/1,
    stream_open_error_stops_the_call/1,
    stream_recv_error_is_the_result/1,
    stream_send_error_cancels/1,
    client_streaming_send_hooks/1,
    stream_close_on_cancel/1,
    derive_replaces_interceptors/1,
    invalid_interceptor_is_an_error/1,
    removed_options_are_errors/1
]).

-define(SERVICE, 'egrpc.test.v1.Echo').
-define(CHECK(Ch), egrpc_grpc_health_v1_health_stub:check(Ch, #{service => <<"s">>})).

all() ->
    [
        unary_wraps_order,
        unary_does_not_fire_stream_hooks,
        unary_wrap_can_call_next_again,
        unary_wrap_changes_result,
        fun_wraps_unary_only,
        streaming_hooks,
        stream_open_error_stops_the_call,
        stream_recv_error_is_the_result,
        stream_send_error_cancels,
        client_streaming_send_hooks,
        stream_close_on_cancel,
        derive_replaces_interceptors,
        invalid_interceptor_is_an_error,
        removed_options_are_errors
    ].

init_per_suite(Config) ->
    ok = egrpc_test_util:start_apps(),
    Config.

end_per_suite(_Config) ->
    ok.

%%--------------------------------------------------------------------
%% Helpers

%% Start a server for the handler and open a channel with the options to it. The `info' of the
%% channel has the test process, which the recorders tell.
with_channel(Handler, Opts, Fun) ->
    {ok, Ref} = egrpc_fake_server:start(Handler),
    Info = maps:merge(#{pid => self()}, maps:get(info, Opts, #{})),
    Ch = egrpc_test_util:open(egrpc_fake_server:port(Ref), Opts#{info => Info}),
    try
        Fun(Ch)
    after
        egrpc_test_util:close(Ch),
        egrpc_fake_server:stop(Ref)
    end.

ok_handler() ->
    fun(_) -> egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING')) end.

%% All the events of the recorders in the mailbox, as `{Tag, Hook, Detail}'.
events() ->
    receive
        {event, Tag, Hook, Detail} -> [{Tag, Hook, Detail} | events()]
    after 200 -> []
    end.

grpc(Method) ->
    #{
        rpc_def => egrpc_test_echo_pb:find_rpc_def(?SERVICE, binary_to_atom(Method)),
        path => <<"/egrpc.test.v1.Echo/", Method/binary>>,
        pb_module => egrpc_test_echo_pb,
        service_name => ?SERVICE
    }.

%%--------------------------------------------------------------------
%% Tests

%% The first interceptor is the outermost, the attempt is inside all of them.
unary_wraps_order(_Config) ->
    Opts = #{interceptors => [egrpc_test_recorder, egrpc_test_recorder_b],
             attempt_hooks => [egrpc_test_recorder]},
    with_channel(ok_handler(), Opts, fun(Ch) ->
        ?assertMatch({ok, #{status := 'SERVING'}}, ?CHECK(Ch)),
        ?assertEqual(
            [
                {a, unary, in}, {b, unary, in},
                {a, attempt_start, 0}, {a, attempt_end, {0, ok}},
                {b, unary, out}, {a, unary, out}
            ],
            events()
        )
    end).

%% A unary call is not a stream: the hooks of a stream are not fired for it.
unary_does_not_fire_stream_hooks(_Config) ->
    with_channel(ok_handler(), #{interceptors => [egrpc_test_recorder]}, fun(Ch) ->
        ?assertMatch({ok, _}, ?CHECK(Ch)),
        ?assertEqual([{a, unary, in}, {a, unary, out}], events())
    end).

%% A wrap can call `Next' again: every call of it is an attempt, and picks again.
unary_wrap_can_call_next_again(_Config) ->
    Counter = atomics:new(1, []),
    Handler = fun(_) ->
        case atomics:add_get(Counter, 1, 1) of
            1 -> egrpc_fake_server:status(16, <<"expired">>);
            _ -> egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING'))
        end
    end,
    Again = fun(Call, Req, Next) ->
        case Next(Call, Req) of
            {error, {grpc_error, unauthenticated, _}} -> Next(Call, Req);
            Other -> Other
        end
    end,
    Opts = #{interceptors => [Again], attempt_hooks => [egrpc_test_recorder]},
    with_channel(Handler, Opts, fun(Ch) ->
        ?assertMatch({ok, #{status := 'SERVING'}}, ?CHECK(Ch)),
        ?assertEqual(
            [{a, attempt_start, 0}, {a, attempt_end, {0, error}},
             {a, attempt_start, 0}, {a, attempt_end, {0, ok}}],
            events()
        ),
        ?assertEqual(2, atomics:get(Counter, 1))
    end).

unary_wrap_changes_result(_Config) ->
    Replace = fun(Call, Req, Next) ->
        case Next(Call, Req) of
            {ok, _} -> {error, replaced};
            Other -> Other
        end
    end,
    with_channel(ok_handler(), #{interceptors => [Replace]}, fun(Ch) ->
        ?assertEqual({error, replaced}, ?CHECK(Ch))
    end).

%% A `fun/3' is a wrap of unary calls, it does not see streaming calls.
fun_wraps_unary_only(_Config) ->
    Pid = self(),
    Fun = fun(Call, Req, Next) ->
        Pid ! {fun_called, egrpc_call:method(Call)},
        Next(Call, Req)
    end,
    with_channel(ok_handler(), #{interceptors => [Fun]}, fun(Ch) ->
        ?assertMatch({ok, _}, ?CHECK(Ch)),
        receive
            {fun_called, <<"/grpc.health.v1.Health/Check">>} -> ok
        after 1000 -> ct:fail(fun_not_called)
        end,
        {ok, Stream} = egrpc_grpc_health_v1_health_stub:watch(Ch, #{service => <<"s">>}),
        {ok, _} = egrpc_stream:recv_header(Stream, 2000),
        receive
            {fun_called, _} -> ct:fail(fun_called_for_a_streaming_call)
        after 200 -> ok
        end
    end).

%% Open, the request, every message, the end of the stream and the status of it.
streaming_hooks(_Config) ->
    Opts = #{interceptors => [egrpc_test_recorder], attempt_hooks => [egrpc_test_recorder]},
    with_channel(ok_handler(), Opts, fun(Ch) ->
        {ok, S0} = egrpc_grpc_health_v1_health_stub:watch(Ch, #{service => <<"s">>}),
        {ok, S1} = egrpc_stream:recv_header(S0, 2000),
        {ok, S2, #{status := 'SERVING'}} = egrpc_stream:recv_msg(S1, 2000),
        ?assertEqual(eof, egrpc_stream:recv_msg(S2, 2000)),
        ?assertEqual(
            [
                {a, stream_open, none},
                {a, attempt_start, 0},
                {a, stream_send, #{service => <<"s">>}},
                {a, stream_recv, none},
                {a, stream_recv, none},
                {a, stream_close, ok},
                {a, attempt_end, {0, ok}}
            ],
            events()
        )
    end).

%% A hook which fails stops the call, nothing is sent.
stream_open_error_stops_the_call(_Config) ->
    Handler = fun(_) -> ct:fail(request_was_sent) end,
    Opts = #{interceptors => [egrpc_test_recorder], info => #{fail => stream_open}},
    with_channel(Handler, Opts, fun(Ch) ->
        ?assertEqual({error, denied},
                     egrpc_grpc_health_v1_health_stub:watch(Ch, #{service => <<"s">>})),
        ?assertEqual([{a, stream_open, none}], events()),
        receive
            {fake_server_request, _} -> ct:fail(request_reached_the_server)
        after 200 -> ok
        end
    end).

stream_recv_error_is_the_result(_Config) ->
    Opts = #{interceptors => [egrpc_test_recorder], info => #{fail => stream_recv}},
    with_channel(ok_handler(), Opts, fun(Ch) ->
        {ok, S0} = egrpc_grpc_health_v1_health_stub:watch(Ch, #{service => <<"s">>}),
        {ok, S1} = egrpc_stream:recv_header(S0, 2000),
        ?assertEqual({error, denied}, egrpc_stream:recv_msg(S1, 2000))
    end).

%% The request of a server streaming call is sent through the hook: when it fails the call fails
%% and the stream is cancelled.
stream_send_error_cancels(_Config) ->
    Opts = #{interceptors => [egrpc_test_recorder], info => #{fail => stream_send}},
    with_channel(ok_handler(), Opts, fun(Ch) ->
        ?assertEqual({error, denied},
                     egrpc_grpc_health_v1_health_stub:watch(Ch, #{service => <<"s">>})),
        ?assertMatch([{a, stream_open, _}, {a, stream_send, _}, {a, stream_close, canceled}],
                     [E || {_, H, _} = E <- events(), H =/= attempt_start, H =/= attempt_end])
    end).

client_streaming_send_hooks(_Config) ->
    Handler = fun(_) ->
        egrpc_fake_server:ok(egrpc_test_echo_pb:encode_msg(#{message => <<"done">>},
                                                           'egrpc.test.v1.EchoResponse'))
    end,
    with_channel(Handler, #{interceptors => [egrpc_test_recorder]}, fun(Ch) ->
        {ok, S0} = egrpc_client:client_streaming(Ch, grpc(<<"ClientStream">>), #{}),
        {ok, S1} = egrpc_stream:send_msg(S0, #{message => <<"x">>}, nofin),
        {ok, S2} = egrpc_stream:send_msg(S1, #{message => <<"y">>}, nofin),
        {ok, S3} = egrpc_stream:close_send(S2),
        {ok, S4} = egrpc_stream:recv_header(S3, 2000),
        {ok, S5, #{message := <<"done">>}} = egrpc_stream:recv_msg(S4, 2000),
        eof = egrpc_stream:recv_msg(S5, 2000),
        ?assertEqual(
            [
                {a, stream_open, none},
                {a, stream_send, #{message => <<"x">>}},
                {a, stream_send, #{message => <<"y">>}},
                {a, stream_recv, none},
                {a, stream_recv, none},
                {a, stream_close, ok}
            ],
            events()
        )
    end).

stream_close_on_cancel(_Config) ->
    Handler = fun(_) -> [{sleep, 1000}] end,
    Opts = #{interceptors => [egrpc_test_recorder]},
    with_channel(Handler, Opts, fun(Ch) ->
        {ok, S} = egrpc_grpc_health_v1_health_stub:watch(Ch, #{service => <<"s">>}),
        ok = egrpc_stream:cancel_stream(S),
        ?assertEqual([{a, stream_open, none}, {a, stream_send, #{service => <<"s">>}},
                      {a, stream_close, canceled}], events())
    end).

%% A derived channel has its own interceptors and the same subchannels.
derive_replaces_interceptors(_Config) ->
    with_channel(ok_handler(), #{interceptors => [egrpc_test_recorder]}, fun(Ch) ->
        Derived = egrpc_channel:derive(Ch, #{interceptors => [egrpc_test_recorder_b]}),
        Bare = egrpc_channel:derive(Ch, #{interceptors => []}),
        ?assertMatch({ok, _}, ?CHECK(Ch)),
        ?assertEqual([{a, unary, in}, {a, unary, out}], events()),
        ?assertMatch({ok, _}, ?CHECK(Derived)),
        ?assertEqual([{b, unary, in}, {b, unary, out}], events()),
        ?assertMatch({ok, _}, ?CHECK(Bare)),
        ?assertEqual([], events())
    end).

invalid_interceptor_is_an_error(_Config) ->
    Opts = fun(Interceptors) -> #{target => "localhost:1", interceptors => Interceptors} end,
    ?assertError({invalid_interceptor, lists}, egrpc_channel:start(nope, Opts([lists]))),
    ?assertError({invalid_interceptor, not_a_module_at_all},
                 egrpc_channel:start(nope, Opts([not_a_module_at_all]))),
    ?assertError({invalid_interceptor, 42}, egrpc_channel:start(nope, Opts([42]))),
    ?assertError({invalid_interceptors, foo}, egrpc_channel:start(nope, Opts(foo))).

removed_options_are_errors(_Config) ->
    ?assertError({invalid_option, unary_interceptors},
                 % eqwalizer:ignore
                 egrpc_channel:start(nope, #{target => "localhost:1", unary_interceptors => []})),
    ?assertError({invalid_option, stream_interceptors},
                 % eqwalizer:ignore
                 egrpc_channel:start(nope, #{target => "localhost:1", stream_interceptors => []})).
