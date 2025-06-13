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
        _:Reason ->
            {error, Reason}
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
    {error, {grpc_error, unimplemented,
                 <<"Compression mechanism ", (atom_to_binary(Encoding, utf8))/binary,
                   " used for received frame not supported">>
            }};
decode(_Encoding, _Decoder, <<_/binary>>) ->
    more.
