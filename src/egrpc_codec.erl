%% @doc This module defines the behaviour for gRPC codecs in egrpc.
%%
%% A codec is responsible for encoding and decoding messages
%% sent and received over gRPC streams.
%%
%% The codec of a channel is the `codec' option of `egrpc_channel:start/2', the default is
%% `m:egrpc_proto'. The request header `content-type' is the `content_type/0' of the codec.
%%
%% See `m:egrpc_proto', `m:egrpc_erlpack', and `m:egrpc_json' for
%% example implementations of this behaviour.
-module(egrpc_codec).

-export([init/2, content_type/1, is_codec/1]).

-export_type([encoder/0, decoder/0]).

-type encoder() :: fun((term()) -> binary()).
-type decoder() :: fun((binary()) -> term()).

-callback init(Opts :: any()) -> {encoder(), decoder()}.

%% The value of the `content-type' header of the requests, `application/grpc' with a suffix which
%% names the encoding: `application/grpc+proto', `application/grpc+json' or a custom one.
-callback content_type() -> binary().

init(Codec, Opts) when is_atom(Codec) ->
    Codec:init(Opts).

%% @doc The `content-type' of the requests of a codec.
-spec content_type(module()) -> binary().
content_type(Codec) when is_atom(Codec) ->
    Codec:content_type().

%% @doc Whether the module is a codec: it exports `init/1' and `content_type/0'.
-spec is_codec(term()) -> boolean().
is_codec(Codec) when is_atom(Codec) ->
    case code:ensure_loaded(Codec) of
        {module, Codec} ->
            erlang:function_exported(Codec, init, 1) andalso
                erlang:function_exported(Codec, content_type, 0);
        _ ->
            false
    end;
is_codec(_) ->
    false.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

is_codec_test() ->
    ?assert(is_codec(egrpc_proto)),
    ?assert(is_codec(egrpc_json)),
    ?assert(is_codec(egrpc_erlpack)),
    ?assertNot(is_codec(lists)),
    ?assertNot(is_codec(not_a_module_at_all)),
    ?assertNot(is_codec("proto")).

content_type_test() ->
    ?assertEqual(<<"application/grpc+proto">>, content_type(egrpc_proto)),
    ?assertEqual(<<"application/grpc+json">>, content_type(egrpc_json)),
    ?assertEqual(<<"application/grpc+erlpack">>, content_type(egrpc_erlpack)).
-endif.
