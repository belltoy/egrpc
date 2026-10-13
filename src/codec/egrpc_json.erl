%% @doc This module provides an egrpc codec implementation using JSON
%% encoding and decoding for gRPC messages.
%%
%% It needs the generated module to have been generated with the `json' option of gpb, and uses the
%% `json' module of OTP 27 to encode and parse the text.
-module(egrpc_json).

-behaviour(egrpc_codec).

-export([init/1, content_type/0]).

-spec init(egrpc:grpc()) -> {egrpc_codec:encoder(), egrpc_codec:decoder()}.
init(#{pb_module := PbModule, rpc_def := RpcDef}) ->
    #{input := Input, output := Output} = RpcDef,
    Encoder = fun(RequestMsg) ->
        iolist_to_binary(json:encode(PbModule:to_json(RequestMsg, Input)))
    end,
    Decoder = fun(ResponseBin) -> PbModule:from_json(json:decode(ResponseBin), Output) end,
    {Encoder, Decoder}.

-spec content_type() -> binary().
content_type() -> <<"application/grpc+json">>.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

roundtrip_test() ->
    Msg = 'grpc.health.v1.HealthCheckRequest',
    {Encoder, Decoder} =
        init(#{pb_module => egrpc_health_pb, rpc_def => #{input => Msg, output => Msg}}),
    Bin = Encoder(#{service => <<"abc">>}),
    ?assert(is_binary(Bin)),
    %% JSON text
    ?assertEqual(#{<<"service">> => <<"abc">>}, json:decode(Bin)),
    ?assertEqual(#{service => <<"abc">>}, Decoder(Bin)),
    ?assertError(_, Decoder(<<"{not json">>)).
-endif.
