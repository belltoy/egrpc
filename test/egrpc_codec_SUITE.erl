%% @doc The codec of a channel: the content type of the requests and the encoding of the
%% messages, against the fake server.
-module(egrpc_codec_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([proto_is_the_default/1, json/1, erlpack/1, invalid_codec/1, codec_is_kept_by_derive/1]).

-define(CHECK(Ch), egrpc_grpc_health_v1_health_client:check(Ch, #{service => <<"s">>})).

all() ->
    [proto_is_the_default, json, erlpack, invalid_codec, codec_is_kept_by_derive].

init_per_suite(Config) ->
    ok = egrpc_test_util:start_apps(),
    Config.

end_per_suite(_Config) ->
    ok.

%% The server answers a unary call with the response frame given, and tells the test process what
%% it received.
call(Opts, Response) ->
    {ok, Ref} = egrpc_fake_server:start(fun(_) ->
        [
            {headers, [{<<"content-type">>, <<"application/grpc">>}]},
            {data, egrpc_fake_server:frame(Response)},
            {trailers, [{<<"grpc-status">>, <<"0">>}]}
        ]
    end),
    {ok, Ch0} = egrpc_stub:open("localhost", egrpc_fake_server:port(Ref), Opts),
    {ok, Ch} = egrpc_stub:await_up(Ch0),
    try
        Result = ?CHECK(Ch),
        receive
            {fake_server_request, Req} -> {Result, Req}
        after 1000 -> ct:fail(no_request)
        end
    after
        egrpc_stub:close(Ch, true),
        egrpc_fake_server:stop(Ref)
    end.

content_type(#{headers := Headers}) -> maps:get(<<"content-type">>, Headers).

proto_is_the_default(_Config) ->
    {Result, Req} = call(#{}, egrpc_test_util:health_response('SERVING')),
    ?assertEqual({ok, #{status => 'SERVING'}}, Result),
    ?assertEqual(<<"application/grpc+proto">>, content_type(Req)).

%% JSON text in both directions.
json(_Config) ->
    {Result, Req} = call(#{codec => egrpc_json}, <<"{\"status\":\"SERVING\"}">>),
    ?assertEqual({ok, #{status => 'SERVING'}}, Result),
    ?assertEqual(<<"application/grpc+json">>, content_type(Req)),
    ?assertEqual(
        egrpc_fake_server:frame(<<"{\"service\":\"s\"}">>),
        maps:get(body, Req)
    ).

erlpack(_Config) ->
    {Result, Req} = call(#{codec => egrpc_erlpack}, term_to_binary(#{status => 'SERVING'})),
    ?assertEqual({ok, #{status => 'SERVING'}}, Result),
    ?assertEqual(<<"application/grpc+erlpack">>, content_type(Req)),
    ?assertEqual(
        egrpc_fake_server:frame(term_to_binary(#{service => <<"s">>})),
        maps:get(body, Req)
    ).

invalid_codec(_Config) ->
    ?assertError({invalid_codec, lists}, egrpc_stub:open("localhost", 1, #{codec => lists})),
    ?assertError({invalid_codec, nope}, egrpc_stub:open("localhost", 1, #{codec => nope})).

%% A derived channel has the codec of the original, it is not an option of derive/2.
codec_is_kept_by_derive(_Config) ->
    {ok, Ch} = egrpc_stub:open("localhost", 1, #{codec => egrpc_json}),
    try
        ?assertEqual(egrpc_json, egrpc_stub:codec(egrpc_stub:derive(Ch, #{info => x}))),
        ?assertError({invalid_option, codec}, egrpc_stub:derive(Ch, #{codec => egrpc_proto}))
    after
        egrpc_stub:close(Ch, true)
    end.
