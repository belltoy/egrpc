-module(egrpc_stream_interceptor).

-export([init/2]).

-export([
    is_impl/3,
    is_behaviour_impl/1
]).

-callback init(Opts :: any()) -> {ok, State :: any()}.

-callback init_request(Stream, Opts, Next, State :: any()) -> Stream when
    Stream :: egrpc:stream(),
    Opts :: map(),
    Next :: fun((Stream, Opts) -> Stream).

-callback send_msg(Stream, Req, IsFin, Next, State) -> Stream when
    Stream :: egrpc:stream(),
    Req :: map(),
    IsFin :: fin | nofin,
    State :: any(),
    Next :: fun((Stream, Req, IsFin) -> Stream).

-callback close_send(Stream, Next, State) -> Stream when
    Stream :: egrpc:stream(),
    State :: any(),
    Next :: fun((Stream) -> Stream).

-callback recv_response_header(Stream, Next, State) -> any() when
    Stream :: egrpc:stream(),
    State :: any(),
    Next :: fun((Stream) -> {ok, Stream} | {error, any()}).

-callback recv_msg(Stream, Buf, Next, State) -> any() when
    Stream :: egrpc:stream(),
    State :: any(),
    Response :: map(),
    Buf :: binary(),
    Rest :: binary(),
    Next :: fun((Stream, Buf) -> {ok, Stream, Response, Rest} | {error, any()}).

-callback parse_msg(Stream, Buf, Next, State) -> any() when
    Stream :: egrpc:stream(),
    Buf :: binary(),
    Response :: map(),
    Rest :: binary(),
    State :: any(),
    Next :: fun((Stream, Buf) -> more | {ok, Stream, Response, Rest} | {error, any()}).

-optional_callbacks([
    init/1,
    init_request/4,
    send_msg/5,
    close_send/3,
    recv_response_header/3,
    recv_msg/4,
    parse_msg/4
]).

-spec init(Interceptor :: module(), InitOpts :: any()) -> {module(), any()}.
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
