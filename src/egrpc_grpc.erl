-module(egrpc_grpc).

-export([encode/2, decode/3]).

-export_type([http_encoding/0]).

-type http_encoding() :: identity | gzip.

-spec encode(http_encoding(), binary()) -> binary().
encode(identity, Bin) ->
    Length = byte_size(Bin),
    <<0, Length:32, Bin/binary>>;
encode(gzip, Bin) ->
    CompressedBin = zlib:gzip(Bin),
    Length = byte_size(CompressedBin),
    <<1, Length:32, CompressedBin/binary>>;
encode(Encoding, _) ->
    throw({error, {unknown_encoding, Encoding}}).

-spec decode(http_encoding(), Decoder, binary()) -> Result when
    Decoder :: egrpc_codec:decoder(),
    Result :: {ok, Msg :: term(), Rest :: binary()}
            | {error, egrpc:grpc_error() | any()}
            | more.
decode(_Encoding, Decoder, <<0, Length:32, Bin:Length/binary, Rest/binary>>) ->
    try
        {ok, Decoder(Bin), Rest}
    catch
        _:_Reason ->
            {error, {grpc_error, internal, <<"Error parsing response proto">>}}
    end;
decode(_Encoding, _Decoder, <<0, _Length:32, _Binary/binary>>) -> more;
decode(gzip, Decoder, <<1, Length:32, Compressed:Length/binary, Rest/binary>>) ->
    try
        Bin = zlib:gunzip(Compressed),
        {ok, Decoder(Bin), Rest}
    catch
        error:data_error ->
            {error, {grpc_error, internal,
                     <<"Could not decompress but compression algorithm gzip is supported">>}};
        _:_Reason ->
            {error, {grpc_error, internal, <<"Error parsing response proto">>}}
    end;
decode(Encoding, _Decoder, <<1, Length:32, _Compressed:Length/binary, _Rest/binary>>) ->
    %% A client reports an unsupported compression of a received message as INTERNAL, UNIMPLEMENTED
    %% is for the server side.
    {error, {grpc_error, internal,
                 <<"Compression mechanism ", (atom_to_binary(Encoding, utf8))/binary,
                   " used for received frame not supported">>
            }};
decode(_Encoding, _Decoder, <<Flag, _/binary>>) when Flag =/= 0, Flag =/= 1 ->
    {error, {grpc_error, internal,
                 <<"Invalid Compressed-Flag: ", (integer_to_binary(Flag))/binary>>}};
decode(_Encoding, _Decoder, <<_/binary>>) ->
    more.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

decode_test() ->
    Decoder = fun(<<"bad">>) -> error(badarg); (Bin) -> Bin end,
    Internal = fun(Msg) -> {error, {grpc_error, internal, Msg}} end,
    ?assertEqual({ok, <<"ab">>, <<"rest">>}, decode(identity, Decoder, <<0, 2:32, "ab", "rest">>)),
    ?assertEqual(Internal(<<"Error parsing response proto">>),
                 decode(identity, Decoder, <<0, 3:32, "bad">>)),
    %% an incomplete frame needs more data
    ?assertEqual(more, decode(identity, Decoder, <<0, 5:32, "ab">>)),
    ?assertEqual(more, decode(identity, Decoder, <<>>)),
    %% compressed frame but the encoding is not supported
    ?assertMatch({error, {grpc_error, internal, _}}, decode(identity, Decoder, <<1, 2:32, "ab">>)),
    %% neither 0 nor 1
    ?assertEqual(Internal(<<"Invalid Compressed-Flag: 2">>), decode(identity, Decoder, <<2, 0:32>>)),
    Gz = zlib:gzip(<<"ab">>),
    ?assertEqual({ok, <<"ab">>, <<>>},
                 decode(gzip, Decoder, <<1, (byte_size(Gz)):32, Gz/binary>>)).
-endif.
