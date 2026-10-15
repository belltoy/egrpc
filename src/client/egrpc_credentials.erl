%% @doc The credentials of a call: the metadata (a token, for example) which is generated for
%% every attempt of a unary call and when a stream is opened. The credentials of the connection
%% are `m:egrpc_transport_credentials'.
%%
%% The `call_credentials' option of `egrpc_channel:start/2' and `egrpc_channel:derive/2' is
%%
%% - `Module', a module which implements this behaviour, `Context' is `undefined',
%% - `{Module, Context}',
%% - `fun((CallInfo) -> {ok, Metadata} | {error, Reason})'.
%%
%% `CallInfo' is `#{method := binary(), service := atom(), attempt := non_neg_integer(), info :=
%% term()}', where `info' is the `info' of the channel. The metadata is a map or a list, the one
%% of the call options takes precedence. `{error, Reason}' ends the attempt without sending it,
%% with `{error, {call_credentials, Reason}}'. An exception of the callback is not caught.
%%
%% A unary call which is retried gets new metadata for every attempt, an established stream keeps
%% what it was opened with: a stream whose token is not valid any more has to be opened again.
-module(egrpc_credentials).

-export([metadata/2]).

-export_type([spec/0, call_info/0]).

-type call_info() :: #{
    method := binary(),
    service := atom(),
    attempt := non_neg_integer(),
    info := term()
}.

-type spec() ::
    module()
    | {module(), Context :: term()}
    | fun((call_info()) -> {ok, map() | [{binary(), binary()}]} | {error, term()}).

-callback metadata(Context :: term(), call_info()) ->
    {ok, map() | [{binary(), binary()}]} | {error, term()}.

%% @private
-spec metadata(undefined | spec(), call_info()) ->
    {ok, egrpc_metadata:metadata()} | {error, term()}.
metadata(undefined, _CallInfo) ->
    {ok, []};
metadata(Fun, CallInfo) when is_function(Fun, 1) ->
    result(Fun(CallInfo));
metadata({Module, Context}, CallInfo) when is_atom(Module) ->
    result(Module:metadata(Context, CallInfo));
metadata(Module, CallInfo) when is_atom(Module) ->
    result(Module:metadata(undefined, CallInfo)).

%% The callback is given by the user, so its return value is checked.
result({ok, Metadata}) when is_map(Metadata); is_list(Metadata) ->
    {ok, egrpc_metadata:normalize(Metadata)};
result({error, _} = Error) ->
    Error;
result(Other) ->
    error({invalid_call_credentials, Other}).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

metadata_test() ->
    Info = #{method => <<"/s/m">>, service => s, attempt => 0, info => i},
    ?assertEqual({ok, []}, metadata(undefined, Info)),
    ?assertEqual({ok, [{<<"a">>, <<"1">>}]}, metadata(fun(_) -> {ok, #{<<"A">> => <<"1">>}} end, Info)),
    ?assertEqual({error, no}, metadata(fun(_) -> {error, no} end, Info)),
    ?assertEqual({ok, [{<<"i">>, <<"i">>}]},
                 metadata(fun(#{info := I}) -> {ok, [{<<"i">>, atom_to_binary(I)}]} end, Info)),
    ?assertError({invalid_call_credentials, x}, metadata(fun(_) -> x end, Info)).
-endif.
