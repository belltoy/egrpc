%% @doc The metadata of a call: a list of `{Key, Value}' with lower case binary keys. A map is
%% accepted wherever a list is.
-module(egrpc_metadata).

-export([normalize/1, merge/2, store/3, lookup/2, custom/1]).

-export_type([metadata/0]).

-type metadata() :: [{binary(), binary()}].

%% @doc A map or a list as a list with lower case keys.
-spec normalize(map() | [{binary() | string() | atom(), binary()}]) -> metadata().
normalize(Map) when is_map(Map) ->
    normalize(maps:to_list(Map));
normalize(List) when is_list(List) ->
    [{key(K), V} || {K, V} <- List].

key(K) when is_binary(K) -> string:lowercase(K);
key(K) when is_atom(K) -> key(atom_to_binary(K));
key(K) when is_list(K) -> key(list_to_binary(K)).

%% @doc The entries of `Over' replace the ones of `Base' with the same key.
-spec merge(metadata(), metadata()) -> metadata().
merge(Base, Over) ->
    Keys = [K || {K, _} <- Over],
    [E || {K, _} = E <- Base, not lists:member(K, Keys)] ++ Over.

-spec store(binary(), binary(), metadata()) -> metadata().
store(Key, Value, Metadata) ->
    merge(Metadata, [{key(Key), Value}]).

-spec lookup(binary(), metadata()) -> binary() | undefined.
lookup(Key, Metadata) ->
    Lower = key(Key),
    case [V || {K, V} <- Metadata, K =:= Lower] of
        [Value | _] -> Value;
        [] -> undefined
    end.

%% @doc Without the `grpc-' entries, which are the ones of the protocol and are not set by the
%% application.
-spec custom(metadata()) -> metadata().
custom(Metadata) ->
    [E || {K, _} = E <- Metadata, string:prefix(K, "grpc-") =:= nomatch].

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

normalize_merge_test() ->
    ?assertEqual([{<<"a">>, <<"1">>}], normalize(#{<<"A">> => <<"1">>})),
    ?assertEqual([{<<"b">>, <<"1">>}], normalize([{b, <<"1">>}])),
    ?assertEqual(
        [{<<"b">>, <<"2">>}, {<<"a">>, <<"3">>}],
        merge([{<<"a">>, <<"1">>}, {<<"b">>, <<"2">>}], [{<<"a">>, <<"3">>}])
    ),
    ?assertEqual(<<"1">>, lookup(<<"A">>, [{<<"a">>, <<"1">>}, {<<"a">>, <<"2">>}])),
    ?assertEqual(undefined, lookup(<<"b">>, [{<<"a">>, <<"1">>}])),
    ?assertEqual([{<<"x">>, <<"1">>}], custom([{<<"grpc-timeout">>, <<"1m">>}, {<<"x">>, <<"1">>}])).
-endif.
