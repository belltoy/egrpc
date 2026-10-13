%% @doc What gun does on `gun:cancel/2' and `gun:flush/1'.
%%
%% The cleanup rules of a failed unary call (REFACTOR.md, 4.5) were derived by reading the source of
%% gun. These tests check the premises by running, without egrpc.
-module(egrpc_gun_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2]).
-export([
    cancel_finished_stream/1,
    cancel_live_stream/1,
    flush_unread_messages/1
]).

all() ->
    [cancel_finished_stream, cancel_live_stream, flush_unread_messages].

init_per_suite(Config) ->
    ok = egrpc_test_util:start_apps(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    ct:timetrap({seconds, 20}),
    Config.

%% Open a connection to a server which runs the actions, and post a request.
request(Actions) ->
    {ok, Ref} = egrpc_fake_server:start(fun(_Request) -> Actions end),
    {ok, Conn} = gun:open("localhost", egrpc_fake_server:port(Ref), #{
        protocols => [http2],
        retry => 0
    }),
    {ok, http2} = gun:await_up(Conn),
    %% cowboy sends trailers only to a client which sent `te: trailers', as a gRPC client does
    Headers = [{<<"content-type">>, <<"application/grpc">>}, {<<"te">>, <<"trailers">>}],
    StreamRef = gun:post(Conn, "/test", Headers, <<>>),
    {Ref, Conn, StreamRef}.

done({Ref, Conn, _StreamRef}) ->
    gun:close(Conn),
    egrpc_fake_server:stop(Ref).

%% A stream which has finished is deleted by gun, cancelling it makes gun send an error to the
%% caller. The unread messages are not touched.
cancel_finished_stream(_Config) ->
    S = {_, Conn, StreamRef} = request(egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING'))),
    {response, nofin, 200, _} = gun:await(Conn, StreamRef, 2000),
    {data, nofin, _} = gun:await(Conn, StreamRef, 2000),
    {trailers, _} = gun:await(Conn, StreamRef, 2000),
    ok = gun:cancel(Conn, StreamRef),
    receive
        {gun_error, Conn, StreamRef, {badstate, "The stream cannot be found."}} -> ok
    after 2000 -> ct:fail(no_gun_error)
    end,
    done(S).

%% Cancelling a stream which is still alive: nothing of it is delivered afterwards, the late
%% response of the server does not reach the mailbox.
cancel_live_stream(_Config) ->
    Actions = [{sleep, 1000} | egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING'))],
    S = {_, Conn, StreamRef} = request(Actions),
    ok = gun:cancel(Conn, StreamRef),
    ok = gun:flush(StreamRef),
    ?assertEqual([], egrpc_test_util:stream_msgs(egrpc_test_util:drain(2500))),
    done(S).

%% `gun:flush/1' removes the messages of a stream which were not read.
flush_unread_messages(_Config) ->
    S = {_, _Conn, StreamRef} = request(egrpc_fake_server:ok(egrpc_test_util:health_response('SERVING'))),
    %% the whole response reaches the mailbox without being read
    timer:sleep(500),
    {messages, Msgs} = process_info(self(), messages),
    ?assertMatch([_, _, _], egrpc_test_util:stream_msgs(Msgs)),
    ok = gun:flush(StreamRef),
    ?assertEqual([], egrpc_test_util:stream_msgs(egrpc_test_util:drain(100))),
    done(S).
