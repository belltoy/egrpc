-module(egrpc_codec).

-export([init/2]).

-export_type([encoder/0, decoder/0]).

-type encoder() :: fun((term()) -> binary()).
-type decoder() :: fun((binary()) -> term()).

-callback init(Opts :: any()) -> {encoder(), decoder()}.

init(Codec, Opts) when is_atom(Codec) ->
    Codec:init(Opts).
