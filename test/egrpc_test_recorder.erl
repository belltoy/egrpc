%% @doc An interceptor for the tests: it tells the test process which hooks fired, in which
%% order, and which state each one saw, and it can fail on a hook.
%%
%% `InitOpts' is `#{tag := term(), pid := pid(), fail => hook()}'. The state is the options and a
%% counter of the hooks which went through this interceptor of the call.
-module(egrpc_test_recorder).

-behaviour(egrpc_interceptor).

-export([init/1, unary/5, init_req/4, send_msg/5, recv_header/4, recv_msg/5, close_send/3,
         parse_msg/4]).

init(#{tag := Tag, pid := Pid} = Opts) ->
    Pid ! {init, Tag},
    Opts#{count => 0}.

%% Tell the test process, return `{error, denied}' when this hook is the one which fails.
note(#{tag := Tag, pid := Pid, count := Count}, Hook, Detail) ->
    Pid ! {event, Tag, Hook, Detail, Count},
    ok.

fails(#{fail := Hook}, Hook) -> true;
fails(_, _) -> false.

bump(#{count := Count} = State) -> State#{count => Count + 1}.

unary(Stream, Req, Opts, Next, State) ->
    note(State, unary, in),
    Result = Next(Stream, Req, Opts),
    note(State, unary, out),
    Result.

init_req(Stream, Opts, Next, State) ->
    note(State, init_req, none),
    hook(State, init_req, fun() -> Next(Stream, Opts) end).

send_msg(Stream, Req, IsFin, Next, State) ->
    note(State, send_msg, IsFin),
    hook(State, send_msg, fun() -> Next(Stream, Req, IsFin) end).

recv_header(Stream, Timeout, Next, State) ->
    note(State, recv_header, none),
    hook(State, recv_header, fun() -> Next(Stream, Timeout) end).

close_send(Stream, Next, State) ->
    note(State, close_send, none),
    hook(State, close_send, fun() -> Next(Stream) end).

recv_msg(Stream, Timeout, Buf, Next, State) ->
    note(State, recv_msg, none),
    case fails(State, recv_msg) of
        true ->
            {error, denied};
        false ->
            case Next(Stream, Timeout, Buf) of
                {ok, Stream1, Resp, Rest} -> {ok, {Stream1, bump(State)}, Resp, Rest};
                {error, _} = Error -> Error
            end
    end.

parse_msg(Stream, Buf, Next, State) ->
    note(State, parse_msg, none),
    case Next(Stream, Buf) of
        {ok, Stream1, Resp, Rest} -> {ok, {Stream1, bump(State)}, Resp, Rest};
        Other -> Other
    end.

hook(State, Hook, Run) ->
    case fails(State, Hook) of
        true ->
            {error, denied};
        false ->
            case Run() of
                {ok, Stream} -> {ok, {Stream, bump(State)}};
                {error, _} = Error -> Error
            end
    end.
