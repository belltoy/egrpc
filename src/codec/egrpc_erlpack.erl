%% @doc This module provides an egrpc codec implementation using Erlang's built-in
%% `erlang:term_to_binary/1' and `erlang:binary_to_term/1' functions for encoding and decoding
%% messages.
-module(egrpc_erlpack).

-behaviour(egrpc_codec).

-export([init/1]).

-spec init(any()) -> {egrpc_codec:encoder(), egrpc_codec:decoder()}.
init(_) ->
    Encoder = fun(Msg) -> erlang:term_to_binary(Msg) end,
    Decoder = fun(Bin) -> erlang:binary_to_term(Bin) end,
    {Encoder, Decoder}.
