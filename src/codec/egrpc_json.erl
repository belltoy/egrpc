-module(egrpc_json).

-behaviour(egrpc_codec).

-export([init/1]).

-spec init(egrpc:grpc()) -> {egrpc_codec:encoder(), egrpc_codec:decoder()}.
init(#{pb_module := PbModule, rpc_def := RpcDef}) ->
    #{input := Input, output := Output} = RpcDef,
    Encoder = fun(RequestMsg) -> PbModule:to_json(RequestMsg, Input) end,
    Decoder = fun(ResponseBin) -> PbModule:from_json(ResponseBin, Output) end,
    {Encoder, Decoder}.
