%% @doc The behaviour of the interceptors of unary calls.
%%
%% An interceptor wraps the logical call, above the retries: it runs once for a call whatever the
%% number of attempts, and does not see the subchannel or the connection. For the lifecycle of
%% a stream see `m:egrpc_stream_interceptor'. What observes every attempt is
%% `m:egrpc_attempt_hooks'.
%%
%% The `interceptors' option of `egrpc_channel:start/2' and `egrpc_channel:derive/2' is a list of
%%
%% - `Module': a module which implements `unary/3' and/or the callbacks of
%%   `m:egrpc_stream_interceptor',
%% - `fun((Call, Request, Next) -> Result)': a function which wraps unary calls.
%%
%% The first element is the outermost: for `[A, B]' a request goes through `A' and then `B', and
%% the response goes through `B' and then `A'. Everything runs in the process of the call.
%%
%% `Next' is `fun((Call, Request) -> Result)'. A wrap can change the call (`m:egrpc_call') and the
%% request, call `Next' more than once, and change the result. The result is `{ok, Response}',
%% `{ok, Response, Metadata}' when the call has `with_metadata', or `{error, Reason}'.
-module(egrpc_interceptor).

-export([validate/1, unary_chain/2, is_impl/3]).

-export_type([spec/0, next/0, result/0]).

-type result() :: {ok, map()} | {ok, map(), map()} | {error, term()}.
-type next() :: fun((egrpc_call:call(), map()) -> result()).
-type spec() :: module() | fun((egrpc_call:call(), map(), next()) -> result()).

-callback unary(egrpc_call:call(), Request :: map(), next()) -> result().

-optional_callbacks([unary/3]).

%% @private
%% @doc Check the list of interceptors and return it.
-spec validate(term()) -> [spec()].
validate(Specs) when is_list(Specs) ->
    lists:foreach(fun validate_spec/1, Specs),
    % eqwalizer:ignore
    Specs;
validate(Other) ->
    error({invalid_interceptors, Other}).

validate_spec(Fun) when is_function(Fun, 3) ->
    ok;
validate_spec(Module) when is_atom(Module), Module =/= undefined ->
    case is_impl(Module, unary, 3) orelse egrpc_stream_interceptor:implements_any(Module) of
        true -> ok;
        false -> error({invalid_interceptor, Module})
    end;
validate_spec(Other) ->
    error({invalid_interceptor, Other}).

%% @private
%% @doc `Next' wrapped by the unary interceptors, the first one is the outermost.
-spec unary_chain([spec()], next()) -> next().
unary_chain(Specs, Next0) ->
    % eqwalizer:ignore
    lists:foldr(
        fun
            (Fun, Next) when is_function(Fun, 3) ->
                fun(Call, Req) -> Fun(Call, Req, Next) end;
            (Module, Next) ->
                % eqwalizer:ignore
                case is_impl(Module, unary, 3) of
                    % eqwalizer:ignore
                    true -> fun(Call, Req) -> Module:unary(Call, Req, Next) end;
                    false -> Next
                end
        end,
        Next0,
        Specs
    ).

%% @private
-spec is_impl(module(), atom(), arity()) -> boolean().
is_impl(Module, Function, Arity) ->
    _ = code:ensure_loaded(Module),
    erlang:function_exported(Module, Function, Arity).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

validate_test() ->
    F = fun(_, _, _) -> ok end,
    ?assertEqual([F], validate([F])),
    ?assertEqual([], validate([])),
    ?assertError({invalid_interceptor, 42}, validate([42])),
    ?assertError({invalid_interceptor, lists}, validate([lists])),
    ?assertError({invalid_interceptors, foo}, validate(foo)),
    ?assertError({invalid_interceptor, _}, validate([fun(_) -> ok end])).

order_test() ->
    Trace = fun(Name) ->
        fun(Call, Req, Next) ->
            self() ! {in, Name},
            R = Next(Call, Req),
            self() ! {out, Name},
            R
        end
    end,
    Chain = unary_chain([Trace(a), Trace(b)], fun(_, _) -> {ok, #{}} end),
    % eqwalizer:ignore
    {ok, #{}} = Chain(call, #{}),
    ?assertEqual([{in, a}, {in, b}, {out, b}, {out, a}], [receive M -> M end || _ <- lists:seq(1, 4)]).
-endif.
