%% @doc How a client chooses a target for a call.
%%
%% `pick_first' goes through the targets in order and takes the first which can serve the call,
%% `round_robin' starts at the next target of the rotation. A target is skipped when it is in
%% `excluded' of the options of the call, when it is `standby' and the call did not ask for it
%% (`hint => #{target => Id}'), or when it has no connection which can take a call.
%%
%% The two are implemented in `egrpc_client', which goes through the ids in the order of `order/3'
%% and asks `eligible/3' for each. A module which implements this behaviour can be given as
%% `balancer => {Module, Opts}', it is called with the targets which can serve the call.
-module(egrpc_balancer).

-export([order/3, eligible/3]).

-export_type([strategy/0, candidate/0]).

-type strategy() :: pick_first | round_robin | {module(), term()}.

-type candidate() :: #{id := term(), attrs := map(), conns := non_neg_integer()}.

%% The choice of a module, `Candidates' are the targets which can serve the call, in order.
-callback pick(Opts :: term(), CallOpts :: map(), Candidates :: [candidate()]) ->
    {ok, Id :: term()} | {error, term()}.

%% @doc The ids of the targets in the order in which they are tried. `Start' is the value of the
%% rotation, it only matters for `round_robin'.
-spec order(pick_first | round_robin, tuple(), non_neg_integer()) -> [term()].
order(_Strategy, Ids, _Start) when tuple_size(Ids) =:= 0 ->
    [];
order(pick_first, Ids, _Start) ->
    tuple_to_list(Ids);
order(round_robin, Ids, Start) ->
    N = tuple_size(Ids),
    [element((Start + I) rem N + 1, Ids) || I <- lists:seq(0, N - 1)].

%% @doc Whether the target may be picked for a call with these options.
-spec eligible(term(), map(), map()) -> boolean().
eligible(Id, Attrs, Opts) ->
    case maps:get(hint, Opts, undefined) of
        #{target := Target} ->
            Id =:= Target;
        _ ->
            not lists:member(Id, maps:get(excluded, Opts, [])) andalso
                maps:get(standby, Attrs, false) =/= true
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

order_test() ->
    Ids = {a, b, c},
    ?assertEqual([a, b, c], order(pick_first, Ids, 7)),
    ?assertEqual([a, b, c], order(round_robin, Ids, 0)),
    ?assertEqual([b, c, a], order(round_robin, Ids, 1)),
    ?assertEqual([c, a, b], order(round_robin, Ids, 5)),
    ?assertEqual([], order(round_robin, {}, 3)).

eligible_test() ->
    ?assert(eligible(a, #{}, #{})),
    ?assertNot(eligible(a, #{}, #{excluded => [a]})),
    ?assert(eligible(b, #{}, #{excluded => [a]})),
    %% a standby target is only picked when it is asked for
    ?assertNot(eligible(s, #{standby => true}, #{})),
    ?assert(eligible(s, #{standby => true}, #{hint => #{target => s}})),
    ?assertNot(eligible(a, #{}, #{hint => #{target => s}})),
    %% a hint wins over `excluded' only for the target which it names
    ?assertNot(eligible(s, #{standby => true}, #{excluded => [s]})).
-endif.
