%% @doc This module provides an egrpc codec implementation using Protocol Buffers (Protobuf)
%% encoding and decoding for gRPC messages.
-module(egrpc_proto).

-behaviour(egrpc_codec).

-export([init/1, content_type/0]).

-spec init(egrpc:grpc()) -> {egrpc_codec:encoder(), egrpc_codec:decoder()}.
init(#{pb_module := PbModule, rpc_def := RpcDef}) ->
    #{input := Input, output := Output} = RpcDef,
    Encoder = fun(RequestMsg) -> PbModule:encode_msg(RequestMsg, Input) end,
    Decoder = fun(ResponseBin) -> PbModule:decode_msg(ResponseBin, Output) end,
    {Encoder, Decoder}.

-spec content_type() -> binary().
content_type() -> <<"application/grpc+proto">>.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

roundtrip_test() ->
    Msg = 'grpc.health.v1.HealthCheckRequest',
    {Encoder, Decoder} = init(#{pb_module => egrpc_health_pb, rpc_def => #{input => Msg, output => Msg}}),
    Bin = Encoder(#{service => <<"abc">>}),
    ?assert(is_binary(Bin)),
    ?assertEqual(#{service => <<"abc">>}, Decoder(Bin)),
    %% A message which does not parse raises, the framing turns it into an error.
    ?assertError(_, Decoder(<<255, 255, 255>>)).
-endif.
