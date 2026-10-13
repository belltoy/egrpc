%% @doc This module provides an egrpc codec implementation using JSON
%% encoding and decoding for gRPC messages.
-module(egrpc_json).

-behaviour(egrpc_codec).

-export([init/1]).

-spec init(egrpc:grpc()) -> {egrpc_codec:encoder(), egrpc_codec:decoder()}.
%% NOTE: `to_json/2' of the generated module returns a JSON term (a map), not the encoded text, and
%% `from_json/2' expects such a term. The encoder here therefore returns a map where
%% `egrpc_grpc:encode/2' needs a binary, so this codec can not send a message as it is. Found by
%% calling it in a test, not verified against a server.
init(#{pb_module := PbModule, rpc_def := RpcDef}) ->
    #{input := Input, output := Output} = RpcDef,
    Encoder = fun(RequestMsg) -> PbModule:to_json(RequestMsg, Input) end,
    Decoder = fun(ResponseBin) -> PbModule:from_json(ResponseBin, Output) end,
    {Encoder, Decoder}.
