-module(egrpc_erlpack).

-behaviour(egrpc_codec).

-export([init/1]).

-spec init(any()) -> {egrpc_codec:encoder(), egrpc_codec:decoder()}.
init(_) ->
    Encoder = fun(Msg) -> erlang:term_to_binary(Msg) end,
    Decoder = fun(Bin) -> erlang:binary_to_term(Bin) end,
    {Encoder, Decoder}.
