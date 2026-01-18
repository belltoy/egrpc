%% @doc This module defines the behaviour for gRPC codecs in egrpc.
%%
%% A codec is responsible for encoding and decoding messages
%% sent and received over gRPC streams.
%%
%% See `m:egrpc_proto', `m:egrpc_erlpack', and `m:egrpc_json' for
%% example implementations of this behaviour.
-module(egrpc_codec).

-export([init/2]).

-export_type([encoder/0, decoder/0]).

-type encoder() :: fun((term()) -> binary()).
-type decoder() :: fun((binary()) -> term()).

-callback init(Opts :: any()) -> {encoder(), decoder()}.

init(Codec, Opts) when is_atom(Codec) ->
    Codec:init(Opts).
