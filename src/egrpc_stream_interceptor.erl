-module(egrpc_stream_interceptor).

-export([init/2]).

-export([
    is_impl/3,
    is_behaviour_impl/1
]).

-callback init(Opts :: any()) -> State :: any().

-callback init_req(Stream, Opts, Next, State) -> {Stream, State} when
    Stream :: egrpc:stream(),
    State :: any(),
    Opts :: map(),
    Next :: fun((Stream, Opts) -> Stream).

-callback send_msg(Stream, Req, IsFin, Next, State) -> {Stream, State} when
    Stream :: egrpc:stream(),
    Req :: map(),
    IsFin :: fin | nofin,
    State :: any(),
    Next :: fun((Stream, Req, IsFin) -> Stream).

-callback close_send(Stream, Next, State) -> {Stream, State} when
    Stream :: egrpc:stream(),
    State :: any(),
    Next :: fun((Stream) -> Stream).

-callback recv_header(Stream, Timeout, Next, State) -> {ok, {Stream, State}} | {error, any()} when
    Stream :: egrpc:stream(),
    Timeout :: erlang:timeout(),
    State :: any(),
    NextRet :: {ok, Stream} | {error, any()},
    Next :: fun((Stream, Timeout) -> NextRet).

-callback recv_msg(Stream, Timeout, Buf, Next, State) -> {ok, {Stream, State}, Response, Rest} |
                                                         {error, any()} when
    Stream :: egrpc:stream(),
    Timeout :: erlang:timeout(),
    State :: any(),
    Response :: map(),
    Buf :: binary(),
    Rest :: binary(),
    NextRet :: {ok, Stream, Response, Rest} | {error, any()},
    Next :: fun((Stream, Timeout, Buf) -> NextRet).

-callback parse_msg(Stream, Buf, Next, State) -> more | {ok, {Stream, State}, Response, Rest} | {error, any()} when
    Stream :: egrpc:stream(),
    Buf :: binary(),
    Response :: map(),
    Rest :: binary(),
    State :: any(),
    NextRet :: more | {ok, Stream, Response, Rest} | {error, any()},
    Next :: fun((Stream, Buf) -> NextRet).

-optional_callbacks([
    init/1,
    init_req/4,
    send_msg/5,
    close_send/3,
    recv_header/4,
    recv_msg/5,
    parse_msg/4
]).

-spec init(Interceptor :: module(), InitOpts :: any()) -> {module(), State :: any()}.
init(I, InitOpts) when is_atom(I) ->
    case is_behaviour_impl(I) andalso function_exported(I, init, 1) of
        true -> {I, I:init(InitOpts)};
        false -> {I, undefined}
    end.

-spec is_impl(Module :: module(), Function :: atom(), Arity :: non_neg_integer()) -> boolean().
is_impl(Module, Function, Arity) ->
    is_behaviour_impl(Module) andalso function_exported(Module, Function, Arity).

-spec is_behaviour_impl(Module :: module()) -> boolean().
is_behaviour_impl(Module) ->
    try
        Attrs = Module:module_info(attributes),
        Behaviours = proplists:get_value(behaviour, Attrs, []),
        % eqwalizer:ignore
        lists:any(fun(B) -> B =:= ?MODULE end, Behaviours)
    catch
        error:undef -> false;
        _:_ -> false
  end.

function_exported(Module, Function, Arity) ->
    try
        Exportes = Module:module_info(exports),
        lists:any(fun({F, A}) -> F =:= Function andalso A =:= Arity end, Exportes)
    catch
        _:_ -> false
    end.
