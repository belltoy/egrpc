-module(egrpc_proto).

-behaviour(egrpc_codec).

-export([init/1]).

-spec init(egrpc:grpc()) -> {egrpc_codec:encoder(), egrpc_codec:decoder()}.
init(#{pb_module := PbModule, rpc_def := RpcDef}) ->
    #{input := Input, output := Output} = RpcDef,
    Encoder = fun(RequestMsg) -> PbModule:encode_msg(RequestMsg, Input) end,
    Decoder = fun(ResponseBin) -> PbModule:decode_msg(ResponseBin, Output) end,
    {Encoder, Decoder}.
