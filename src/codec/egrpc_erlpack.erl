%% @doc This module provides an egrpc codec implementation using Erlang's built-in
%% `erlang:term_to_binary/1' and `erlang:binary_to_term/1' functions for encoding and decoding
%% messages.
-module(egrpc_erlpack).

-behaviour(egrpc_codec).

-export([init/1, content_type/0]).

-spec init(any()) -> {egrpc_codec:encoder(), egrpc_codec:decoder()}.
init(_) ->
    Encoder = fun(Msg) -> erlang:term_to_binary(Msg) end,
    Decoder = fun(Bin) -> erlang:binary_to_term(Bin) end,
    {Encoder, Decoder}.

%% Not a standard encoding, the gRPC protocol allows a custom suffix.
-spec content_type() -> binary().
content_type() -> <<"application/grpc+erlpack">>.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

roundtrip_test() ->
    {Encoder, Decoder} = init(undefined),
    Term = #{a => 1, b => [<<"x">>, {y, 2}]},
    ?assertEqual(Term, Decoder(Encoder(Term))),
    ?assertError(badarg, Decoder(<<"not a term">>)).
-endif.
