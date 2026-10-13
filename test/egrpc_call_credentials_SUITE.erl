%% @doc The call credentials of a channel: what is sent, the precedence, and the errors.
-module(egrpc_call_credentials_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    sent_in_the_request/1,
    call_metadata_takes_precedence/1,
    reserved_prefix_is_dropped/1,
    error_is_not_sent/1,
    invalid_return_raises/1,
    exception_is_not_caught/1,
    called_again_on_retry/1,
    derived_channel_has_its_own/1,
    streaming_call/1,
    invalid_option/1
]).

-define(CHECK(Ch, Opts), egrpc_grpc_health_v1_health_client:check(Ch, #{service => <<"s">>}, Opts)).

all() ->
    [
        sent_in_the_request,
        call_metadata_takes_precedence,
        reserved_prefix_is_dropped,
        error_is_not_sent,
        invalid_return_raises,
        exception_is_not_caught,
        called_again_on_retry,
        derived_channel_has_its_own,
        streaming_call,
        invalid_option
    ].

init_per_suite(Config) ->
    ok = egrpc_test_util:start_apps(),
    Config.

end_per_suite(_Config) ->
    ok.

with_channel(Handler, Opts, Fun) ->
    {ok, Ref} = egrpc_fake_server:start(Handler),
    {ok, Ch0} = egrpc_stub:open("localhost", egrpc_fake_server:port(Ref), Opts),
    {ok, Ch} = egrpc_stub:await_up(Ch0),
    try
        Fun(Ch)
    after
        egrpc_stub:close(Ch, true),
        egrpc_fake_server:stop(Ref)
    end.

ok_handler() ->
    fun(_) -> egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING')) end.

request_headers() ->
    receive
        {fake_server_request, #{headers := Headers}} -> Headers
    after 1000 -> ct:fail(no_request)
    end.

sent_in_the_request(_Config) ->
    Cred = fun(_Stream) -> {ok, #{<<"token">> => <<"t1">>}} end,
    with_channel(ok_handler(), #{call_credentials => Cred}, fun(Ch) ->
        ?assertMatch({ok, _}, ?CHECK(Ch, #{})),
        ?assertEqual(<<"t1">>, maps:get(<<"token">>, request_headers()))
    end).

call_metadata_takes_precedence(_Config) ->
    Cred = fun(_Stream) -> {ok, #{<<"token">> => <<"from-credentials">>, <<"x">> => <<"1">>}} end,
    with_channel(ok_handler(), #{call_credentials => Cred}, fun(Ch) ->
        ?assertMatch({ok, _}, ?CHECK(Ch, #{metadata => #{<<"token">> => <<"from-call">>}})),
        Headers = request_headers(),
        ?assertEqual(<<"from-call">>, maps:get(<<"token">>, Headers)),
        ?assertEqual(<<"1">>, maps:get(<<"x">>, Headers))
    end).

reserved_prefix_is_dropped(_Config) ->
    Cred = fun(_Stream) -> {ok, #{<<"grpc-reserved">> => <<"v">>, <<"ok">> => <<"v">>}} end,
    with_channel(ok_handler(), #{call_credentials => Cred}, fun(Ch) ->
        ?assertMatch({ok, _}, ?CHECK(Ch, #{})),
        Headers = request_headers(),
        ?assertNot(maps:is_key(<<"grpc-reserved">>, Headers)),
        ?assert(maps:is_key(<<"ok">>, Headers))
    end).

%% Nothing is sent when the credentials are not available.
error_is_not_sent(_Config) ->
    Cred = fun(_Stream) -> {error, no_token} end,
    with_channel(fun(_) -> ct:fail(request_was_sent) end, #{call_credentials => Cred}, fun(Ch) ->
        ?assertEqual({error, {call_credentials, no_token}}, ?CHECK(Ch, #{})),
        receive
            {fake_server_request, _} -> ct:fail(request_reached_the_server)
        after 200 -> ok
        end
    end).

invalid_return_raises(_Config) ->
    Cred = fun(_Stream) -> ok end,
    with_channel(ok_handler(), #{call_credentials => Cred}, fun(Ch) ->
        ?assertError({invalid_call_credentials, ok}, ?CHECK(Ch, #{}))
    end).

exception_is_not_caught(_Config) ->
    Cred = fun(_Stream) -> error(boom) end,
    with_channel(ok_handler(), #{call_credentials => Cred}, fun(Ch) ->
        ?assertError(boom, ?CHECK(Ch, #{}))
    end).

%% An interceptor which refreshes the token and calls `Next' again: the credentials are read again.
called_again_on_retry(_Config) ->
    put(token, <<"old">>),
    Cred = fun(_Stream) -> {ok, #{<<"token">> => get(token)}} end,
    Handler = fun(#{headers := #{<<"token">> := Token}}) ->
        case Token of
            <<"old">> -> egrpc_fake_server:status(16, <<"expired">>);
            <<"new">> -> egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING'))
        end
    end,
    Refresh = fun(Stream, Req, Opts, Next) ->
        case Next(Stream, Req, Opts) of
            {error, {grpc_error, unauthenticated, _}} ->
                put(token, <<"new">>),
                Next(Stream, Req, Opts);
            Other ->
                Other
        end
    end,
    with_channel(Handler, #{call_credentials => Cred, interceptors => [Refresh]}, fun(Ch) ->
        ?assertMatch({ok, #{status := 'SERVING'}}, ?CHECK(Ch, #{}))
    end).

derived_channel_has_its_own(_Config) ->
    A = fun(_Stream) -> {ok, #{<<"token">> => <<"a">>}} end,
    B = fun(_Stream) -> {ok, #{<<"token">> => <<"b">>}} end,
    with_channel(ok_handler(), #{call_credentials => A}, fun(Ch) ->
        Derived = egrpc_stub:derive(Ch, #{call_credentials => B}),
        Cleared = egrpc_stub:derive(Ch, #{call_credentials => undefined}),
        Kept = egrpc_stub:derive(Derived, #{info => x}),
        ?assertMatch({ok, _}, ?CHECK(Derived, #{})),
        ?assertEqual(<<"b">>, maps:get(<<"token">>, request_headers())),
        ?assertMatch({ok, _}, ?CHECK(Ch, #{})),
        ?assertEqual(<<"a">>, maps:get(<<"token">>, request_headers())),
        ?assertMatch({ok, _}, ?CHECK(Cleared, #{})),
        ?assertNot(maps:is_key(<<"token">>, request_headers())),
        ?assertMatch({ok, _}, ?CHECK(Kept, #{})),
        ?assertEqual(<<"b">>, maps:get(<<"token">>, request_headers()))
    end).

%% Once, when the stream is opened.
streaming_call(_Config) ->
    Pid = self(),
    Cred = fun(Stream) ->
        Pid ! {credentials, egrpc_stream:grpc_method(Stream)},
        {ok, #{<<"token">> => <<"s">>}}
    end,
    with_channel(ok_handler(), #{call_credentials => Cred}, fun(Ch) ->
        {ok, Stream} = egrpc_grpc_health_v1_health_client:watch(Ch, #{service => <<"s">>}),
        {ok, _} = egrpc_stream:recv_header(Stream, 2000),
        ?assertEqual(<<"s">>, maps:get(<<"token">>, request_headers())),
        receive
            {credentials, 'Watch'} -> ok
        after 1000 -> ct:fail(credentials_not_called)
        end,
        receive
            {credentials, _} -> ct:fail(called_more_than_once)
        after 200 -> ok
        end
    end).

invalid_option(_Config) ->
    ?assertError({invalid_call_credentials, not_a_fun},
                 egrpc_stub:open("localhost", 1, #{call_credentials => not_a_fun})).
