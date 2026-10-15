%% The callbacks of the recorders of the tests: they tell the test process (the `pid' of the `info'
%% of the channel) which hooks fired and in which order, and can fail on a hook (`fail' of the info).
%% The module which includes this file defines `TAG'.
-behaviour(egrpc_interceptor).
-behaviour(egrpc_stream_interceptor).
-behaviour(egrpc_attempt_hooks).

-export([unary/3, stream_open/2, stream_send/3, stream_recv/3, stream_close/2,
         on_attempt_start/1, on_attempt_end/2]).

note(#{pid := Pid}, Hook, Detail) ->
    Pid ! {event, ?TAG, Hook, Detail},
    ok;
note(_, _, _) ->
    ok.

fails(#{fail := Hook}, Hook) -> true;
fails(_, _) -> false.

unary(Call, Req, Next) ->
    Info = egrpc_call:info(Call),
    note(Info, unary, in),
    Result = Next(Call, Req),
    note(Info, unary, out),
    Result.

stream_open(Call, Next) ->
    Info = egrpc_call:info(Call),
    note(Info, stream_open, none),
    case fails(Info, stream_open) of
        true -> {error, denied};
        false -> Next(Call)
    end.

stream_send(Stream, Msg, Next) ->
    Info = egrpc_stream:info(Stream),
    note(Info, stream_send, Msg),
    case fails(Info, stream_send) of
        true -> {error, denied};
        false -> Next(Stream, Msg)
    end.

stream_recv(Stream, Timeout, Next) ->
    Info = egrpc_stream:info(Stream),
    note(Info, stream_recv, none),
    case fails(Info, stream_recv) of
        true -> {error, denied};
        false -> Next(Stream, Timeout)
    end.

stream_close(Stream, Status) ->
    note(egrpc_stream:info(Stream), stream_close, element(2, Status)),
    ok.

%% The attempt hooks run in the process of the call, which is the test process.
on_attempt_start(Attempt) ->
    self() ! {event, ?TAG, attempt_start, egrpc_attempt:number(Attempt)},
    ok.

on_attempt_end(Attempt, {Outcome, _Status}) ->
    self() ! {event, ?TAG, attempt_end, {egrpc_attempt:number(Attempt), Outcome}},
    ok.
