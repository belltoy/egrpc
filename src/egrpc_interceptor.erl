%% @doc The behaviour of interceptors in egrpc.
%%
%% An interceptor is configured in the `interceptors' option of `egrpc_stub:open/3' or
%% `egrpc_stub:derive/2', as a list of
%%
%% <ul>
%% <li>`Module': a module which implements this behaviour,</li>
%% <li>`{Module, InitOpts}': the same, `InitOpts' is given to `Module:init/1',</li>
%% <li>`fun((Stream, Req, Opts, Next) -> Result)': a stateless interceptor which only wraps
%% unary calls, the same as a module which only implements `unary/5'.</li>
%% </ul>
%%
%% All the callbacks are optional.
%%
%% == Order ==
%%
%% The first element of the list is the outermost. For `[A, B]' a request goes through `A' and
%% then `B', and the response goes through `B' and then `A'.
%%
%% == Calls ==
%%
%% Everything runs in the process which makes the call.
%%
%% `unary/5' wraps a whole unary call, it can change the request and the options, call `Next' more
%% than once to retry, and change the result. All the `unary/5' of the list are outside of all the
%% hooks.
%%
%% The hooks `init_req/4', `send_msg/5', `recv_header/4' and `recv_msg/5' fire for all kinds of
%% calls: a unary call is a stream with one message in each direction, `send_msg/5' is called once
%% with `IsFin = fin' and `recv_msg/5' once with an empty buffer. `close_send/3' and `parse_msg/4'
%% only make sense for streaming calls and do not fire for a unary call.
%%
%% A hook can return `{error, Reason}' to stop the call, the call is not sent any further.
%%
%% == State ==
%%
%% `State' is what `init/1' returned. The state given to a hook is threaded through the hooks of
%% one call, and is kept in the stream. The state given to `unary/5' is the result of `init/1',
%% a wrap can not change it. A wrap and the hooks do not share state: a wrap which needs "before"
%% and "after" uses local variables.
%%
%% The state is kept by the position in the list, so the same module can be configured more than
%% once, each with its own state.
-module(egrpc_interceptor).

-export([load/1]).
-export([is_impl/3]).

-export_type([spec/0, item/0, states/0]).

-type spec() ::
    module()
    | {module(), InitOpts :: term()}
    | fun((egrpc:stream(), map(), egrpc_stub:opts(), egrpc_stub:next()) -> egrpc_stub:unary_interceptor_ret()).

%% The interceptor of a list after validation.
-type item() :: {module, module()} | {'fun', function()}.

-type states() :: #{pos_integer() => term()}.

-type hook_ret() :: {ok, {egrpc:stream(), State :: term()}} | {error, term()}.

-export_type([hook_ret/0]).

-callback init(InitOpts :: term()) -> State :: term().

%% Wraps a whole unary call.
-callback unary(Stream, Req, Opts, Next, State) -> Result when
    Stream :: egrpc:stream(),
    Req :: map(),
    Opts :: egrpc_stub:opts(),
    Next :: fun((Stream, Req, Opts) -> Result),
    State :: term(),
    Result :: {ok, map()} | {error, term()}.

-callback init_req(Stream, Opts, Next, State) -> hook_ret() when
    Stream :: egrpc:stream(),
    Opts :: egrpc_stub:opts(),
    Next :: fun((Stream, Opts) -> {ok, Stream} | {error, term()}),
    State :: term().

-callback send_msg(Stream, Req, IsFin, Next, State) -> hook_ret() when
    Stream :: egrpc:stream(),
    Req :: map(),
    IsFin :: fin | nofin,
    Next :: fun((Stream, Req, IsFin) -> {ok, Stream} | {error, term()}),
    State :: term().

-callback recv_header(Stream, Timeout, Next, State) -> hook_ret() when
    Stream :: egrpc:stream(),
    Timeout :: timeout(),
    Next :: fun((Stream, Timeout) -> {ok, Stream} | {error, term()}),
    State :: term().

-callback recv_msg(Stream, Timeout, Buf, Next, State) ->
    {ok, {Stream, State}, Response :: map(), Rest :: binary()} | {error, term()}
when
    Stream :: egrpc:stream(),
    Timeout :: timeout(),
    Buf :: binary(),
    Next :: fun((Stream, Timeout, Buf) ->
        {ok, Stream, Response :: map(), Rest :: binary()} | {error, term()}),
    State :: term().

%% Streaming calls only.
-callback close_send(Stream, Next, State) -> hook_ret() when
    Stream :: egrpc:stream(),
    Next :: fun((Stream) -> {ok, Stream} | {error, term()}),
    State :: term().

%% Streaming calls only.
-callback parse_msg(Stream, Buf, Next, State) ->
    more | {ok, {Stream, State}, Response :: map(), Rest :: binary()} | {error, term()}
when
    Stream :: egrpc:stream(),
    Buf :: binary(),
    Next :: fun((Stream, Buf) ->
        more | {ok, Stream, Response :: map(), Rest :: binary()} | {error, term()}),
    State :: term().

-optional_callbacks([
    init/1,
    unary/5,
    init_req/4,
    send_msg/5,
    recv_header/4,
    recv_msg/5,
    close_send/3,
    parse_msg/4
]).

%% @private
%% @doc Validate the interceptors and initialize them.
%%
%% Return the validated interceptors and their initial state by position. Raise
%% `error({invalid_interceptor, Spec})' for an element which is neither a `fun/4' nor a module
%% which implements the behaviour, and `error({invalid_interceptors, Specs})' when it is not a list.
-spec load([spec()]) -> {[item()], states()}.
load(Specs) when is_list(Specs) ->
    {Items, States, _} = lists:foldl(
        fun(Spec, {Items0, States0, Idx}) ->
            {Item, State} = load_one(Spec),
            % eqwalizer:ignore
            {[Item | Items0], States0#{Idx => State}, Idx + 1}
        end,
        {[], #{}, 1},
        Specs
    ),
    % eqwalizer:ignore
    {lists:reverse(Items), States};
load(Specs) ->
    error({invalid_interceptors, Specs}).

load_one(Fun) when is_function(Fun, 4) ->
    {{'fun', Fun}, undefined};
load_one(Module) when is_atom(Module) ->
    load_module(Module, [], Module);
load_one({Module, InitOpts} = Spec) when is_atom(Module) ->
    load_module(Module, InitOpts, Spec);
load_one(Spec) ->
    error({invalid_interceptor, Spec}).

load_module(Module, InitOpts, Spec) ->
    case is_behaviour_impl(Module) of
        true ->
            State =
                case is_impl(Module, init, 1) of
                    true -> Module:init(InitOpts);
                    false -> undefined
                end,
            {{module, Module}, State};
        false ->
            error({invalid_interceptor, Spec})
    end.

%% @private
-spec is_impl(module(), atom(), non_neg_integer()) -> boolean().
is_impl(Module, Function, Arity) ->
    try
        lists:member({Function, Arity}, Module:module_info(exports))
    catch
        _:_ -> false
    end.

is_behaviour_impl(Module) ->
    try
        Attrs = Module:module_info(attributes),
        % eqwalizer:ignore
        Behaviours = proplists:get_value(behaviour, Attrs, []) ++
            % eqwalizer:ignore
            proplists:get_value(behavior, Attrs, []),
        lists:member(?MODULE, Behaviours)
    catch
        _:_ -> false
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

load_test() ->
    Fun = fun(_Stream, _Req, _Opts, _Next) -> ok end,
    %% a fun is kept as it is, a module of this application implements the behaviour
    ?assertEqual({[{'fun', Fun}], #{1 => undefined}}, load([Fun])),
    ?assertEqual({[], #{}}, load([])),
    %% the state is by position, the same fun twice is two entries
    ?assertMatch({[{'fun', _}, {'fun', _}], #{1 := undefined, 2 := undefined}}, load([Fun, Fun])).

load_invalid_test() ->
    % eqwalizer:ignore
    ?assertError({invalid_interceptor, 42}, load([42])),
    ?assertError({invalid_interceptor, not_a_module_at_all}, load([not_a_module_at_all])),
    %% a module which does not implement the behaviour
    ?assertError({invalid_interceptor, lists}, load([lists])),
    ?assertError({invalid_interceptor, {lists, []}}, load([{lists, []}])),
    %% a fun of the wrong arity
    Fun3 = fun(_, _, _) -> ok end,
    % eqwalizer:ignore
    ?assertError({invalid_interceptor, Fun3}, load([Fun3])),
    % eqwalizer:ignore
    ?assertError({invalid_interceptors, foo}, load(foo)).
-endif.
