%% @doc The retry engine of a logical call: it makes the attempts, and decides after every one if
%% there is another.
%%
%% Every attempt picks its subchannel again, and goes through the credentials, so the
%% interceptors (which are above the engine) are not run again. The deadline of the call is shared
%% by all the attempts, a retry does not reset it.
%%
%% == Policy ==
%%
%% The `retry' option of the channel, and of a call (`false' turns it off, a map changes the
%% keys which it has). Without it a call is made once.
%%
%% - `max_attempts' (3): the attempts of the call, the first one included;
%% - `initial_backoff' (50), `max_backoff' (1000), `multiplier' (2): the wait before the attempt
%%   `n + 1' is a random time up to `min(max_backoff, initial_backoff * multiplier^(n-1))' ms;
%% - `retryable_codes' ([unavailable]): the statuses of the server which are retried;
%% - `retry_non_idempotent' (false): whether the methods which are not `IDEMPOTENT' or
%%   `NO_SIDE_EFFECTS' in the proto are retried when the request may have been processed.
%%
%% == What is retried ==
%%
%% - The request was not sent (`{transport, not_sent}' of `egrpc_error:class/1': the server went
%%   away with `GOAWAY', refused the stream, or the connection was closing): once for a call, at
%%   once, any method, and it does not use the budget.
%% - The request may have been processed (the transport failed, or a status of
%%   `retryable_codes'): only for idempotent methods, up to `max_attempts', with the wait, and
%%   while the budget has tokens.
%% - Not a failure to get a subchannel, that is for the policy of waiting for ready.
%%
%% The budget is a count of tokens for the channel (`retry_budget': `max_tokens' 100,
%% `token_ratio' 0.1): a failure takes a token and a success gives back `token_ratio', nothing is
%% retried while the channel has half of `max_tokens' or fewer. What to retry beyond this is the
%% policy of the protocol above egrpc, it chooses with the options of the call.
-module(egrpc_retry).

-include("egrpc_internal.hrl").

-export([defaults/1, new_budget/1, run/2]).
-export_type([budget/0]).

-type budget() :: {atomics:atomics_ref(), Max :: pos_integer(), Ratio :: number()}.

-define(DEFAULTS, #{
    max_attempts => 3,
    initial_backoff => 50,
    max_backoff => 1000,
    multiplier => 2,
    retryable_codes => [unavailable],
    retry_non_idempotent => false
}).

%% @private
%% @doc The policy with the defaults, `Opts' is the `retry' option of the channel.
-spec defaults(map()) -> map().
defaults(Opts) ->
    Keys = maps:keys(?DEFAULTS),
    case [K || K <- maps:keys(Opts), not lists:member(K, Keys)] of
        [] -> ok;
        [Key | _] -> error({invalid_option, {retry, Key}})
    end,
    maps:merge(?DEFAULTS, Opts).

%% @private
%% @doc The budget of a channel, in thousandths of a token.
-spec new_budget(map()) -> budget().
new_budget(Opts) ->
    #{max_tokens := Max, token_ratio := Ratio} = maps:merge(#{max_tokens => 100, token_ratio => 0.1}, Opts),
    Atomics = atomics:new(1, [{signed, true}]),
    ok = atomics:put(Atomics, 1, Max * 1000),
    {Atomics, Max, Ratio}.

%% @private
%% @doc Run the attempts. `Attempt(Number, Previous)' makes one and returns the result of it and
%% the attempt which was made.
-spec run(egrpc_call:call(), fun((non_neg_integer(), [term()]) -> {Result, egrpc_attempt:info()})) ->
    Result when Result :: term().
run(Call, Attempt) ->
    Policy = egrpc_call:retry_policy(Call),
    Budget = budget_of(Call),
    loop(Call, Attempt, Policy, Budget, 0, [], false).

budget_of(Call) ->
    #egrpc_channel_ref{options = Opts} = egrpc_call:channel(Call),
    maps:get(retry_budget, Opts, undefined).

loop(Call, Attempt, Policy, Budget, N, Previous, Transparent) ->
    {Result, Info} = Attempt(N, Previous),
    case Result of
        {ok, _} ->
            ok = success(Budget),
            Result;
        {ok, _, _} ->
            ok = success(Budget),
            Result;
        {error, _} when Policy =:= undefined ->
            Result;
        {error, Reason} ->
            case egrpc_attempt:subchannel(Info) of
                undefined ->
                    %% never got a subchannel
                    Result;
                SubId ->
                    decide(Call, Attempt, Policy, Budget, N, [SubId | Previous], Transparent, Reason, Result)
            end
    end.

decide(Call, Attempt, Policy, Budget, N, Previous, Transparent, Reason, Result) ->
    case egrpc_error:class(Reason) of
        {transport, not_sent} when not Transparent ->
            %% the server did not process it: any method, once, at once
            loop(Call, Attempt, Policy, Budget, N + 1, Previous, true);
        Class ->
            Retryable = Class =:= {transport, unknown} orelse retryable_code(Class, Policy),
            MayRetry = Retryable andalso allowed(Call, Policy) andalso N + 1 < maps:get(max_attempts, Policy),
            case MayRetry andalso failure(Budget) andalso wait(N + 1, Policy, Call) of
                true -> loop(Call, Attempt, Policy, Budget, N + 1, Previous, Transparent);
                false -> Result
            end
    end.

retryable_code({grpc, Name}, #{retryable_codes := Codes}) -> lists:member(Name, Codes);
retryable_code(_, _) -> false.

allowed(Call, #{retry_non_idempotent := true}) ->
    _ = Call,
    true;
allowed(Call, _Policy) ->
    egrpc_method:idempotent(egrpc_call:grpc(Call)).

%% Wait before the attempt after `N' ones: a random time up to the backoff, which does not go past
%% the deadline. `false' when the deadline would pass.
wait(N, #{initial_backoff := Initial, max_backoff := Max, multiplier := Mult}, Call) ->
    Cap = min(Max, round(Initial * math:pow(Mult, N - 1))),
    % eqwalizer:ignore
    Delay = rand:uniform(Cap + 1) - 1,
    case egrpc_call:remaining(Call) of
        infinity ->
            timer:sleep(Delay),
            true;
        Left when Left > Delay ->
            timer:sleep(Delay),
            true;
        _ ->
            false
    end.

%% The tokens are in thousandths. A failure takes a token and tells whether enough are left.
success(undefined) ->
    ok;
success({Atomics, Max, Ratio}) ->
    Inc = round(Ratio * 1000),
    _ = update(Atomics, fun(V) -> min(Max * 1000, V + Inc) end),
    ok.

failure(undefined) ->
    true;
failure({Atomics, Max, _Ratio}) ->
    New = update(Atomics, fun(V) -> max(0, V - 1000) end),
    New > Max * 1000 div 2.

%% Compare and swap loop: concurrent callers do not lose each other's updates. Returns the new value.
update(Atomics, Fun) ->
    update(Atomics, Fun, atomics:get(Atomics, 1)).

update(Atomics, Fun, Old) ->
    New = Fun(Old),
    case atomics:compare_exchange(Atomics, 1, Old, New) of
        ok -> New;
        Actual -> update(Atomics, Fun, Actual)
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

concurrently(N, Fun) ->
    Self = self(),
    Flag = atomics:new(1, []),
    Pids = [spawn_link(fun() ->
        ok = spin(Flag),
        Self ! {self(), Fun()}
    end) || _ <- lists:seq(1, N)],
    timer:sleep(5),
    ok = atomics:put(Flag, 1, 1),
    [receive {P, R} -> R end || P <- Pids].

spin(Flag) ->
    case atomics:get(Flag, 1) of
        0 -> spin(Flag);
        1 -> ok
    end.

-define(ROUNDS, 200).

budget_does_not_lose_updates_test() ->
    [begin
         {A, _, _} = B = new_budget(#{max_tokens => 1000, token_ratio => 1.0}),
         concurrently(8, fun() -> failure(B) end),
         ?assertEqual(1000 * 1000 - 8 * 1000, atomics:get(A, 1)),
         concurrently(8, fun() -> success(B) end),
         ?assertEqual(1000 * 1000, atomics:get(A, 1))
     end || _ <- lists:seq(1, ?ROUNDS)],
    ok.

budget_stays_within_bounds_test() ->
    {A, _, _} = B = new_budget(#{max_tokens => 10, token_ratio => 0.5}),
    concurrently(100, fun() -> success(B) end),
    ?assertEqual(10 * 1000, atomics:get(A, 1)),
    concurrently(20, fun() -> failure(B) end),
    ?assertEqual(0, atomics:get(A, 1)).

budget_half_test() ->
    B = new_budget(#{max_tokens => 4, token_ratio => 0}),
    %% 4 -> 3 -> 2 (not above half any more)
    ?assert(failure(B)),
    ?assertNot(failure(B)).

defaults_test() ->
    ?assertMatch(#{max_attempts := 3, retryable_codes := [unavailable]}, defaults(#{})),
    ?assertMatch(#{max_attempts := 5}, defaults(#{max_attempts => 5})),
    ?assertError({invalid_option, {retry, foo}}, defaults(#{foo => 1})).
-endif.
