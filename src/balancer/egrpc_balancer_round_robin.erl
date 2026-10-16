%% @doc Round robin: a subchannel for every endpoint, the calls go to the ready ones in turn.
%%
%% The counter is an `atomics' which lives as long as the balancer, so the rotation goes on when a
%% new picker is published.
-module(egrpc_balancer_round_robin).

-behaviour(egrpc_balancer).
-behaviour(egrpc_picker).

-include("egrpc_internal.hrl").

-export([init/1, update_endpoints/2, subchannel_state_changed/3, picker/1]).
-export([pick/2]).

-record(state, {
    endpoints = [] :: [#egrpc_endpoint{}],
    states = #{} :: #{term() => egrpc_balancer:conn_state()},
    counter :: atomics:atomics_ref()
}).

init(_Config) ->
    {ok, #state{counter = atomics:new(1, [])}}.

update_endpoints(New, #state{endpoints = Old, states = States0} = State) ->
    {Removed, Added} = egrpc_balancer:diff(Old, New),
    States1 = maps:without(Removed, States0),
    States = maps:merge(States1, #{Id => idle || #egrpc_endpoint{id = Id} <- Added}),
    Actions =
        [{remove_subchannel, Id} || Id <- Removed] ++
        lists:append([[{create_subchannel, E}, {connect, Id}] || #egrpc_endpoint{id = Id} = E <- Added]),
    {ok, Actions, State#state{endpoints = New, states = States}}.

subchannel_state_changed(Id, ConnState, #state{states = States} = State) ->
    case maps:is_key(Id, States) of
        true -> {ok, [], State#state{states = States#{Id := ConnState}}};
        false -> {ok, [], State}
    end.

picker(#state{endpoints = Endpoints, states = States, counter = Counter}) ->
    Ready = [Id || #egrpc_endpoint{id = Id} <- Endpoints, maps:get(Id, States, idle) =:= ready],
    case Ready of
        [] -> egrpc_picker:failing(no_ready_subchannel);
        _ -> egrpc_picker:new(?MODULE, {list_to_tuple(Ready), Counter})
    end.

%% @private
pick({Ready, Counter}, #egrpc_pick_info{previous_subchannels = Previous}) ->
    N = tuple_size(Ready),
    Start = atomics:add_get(Counter, 1, 1) - 1,
    Order = [element((Start + I) rem N + 1, Ready) || I <- lists:seq(0, N - 1)],
    Id = case [I || I <- Order, not lists:member(I, Previous)] of
        [First | _] -> First;
        [] -> hd(Order)
    end,
    {ok, #egrpc_pick_result{subchannel = Id, done = egrpc_picker:default_done()}}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

ep(Id) ->
    #egrpc_endpoint{id = Id, addresses = [#egrpc_address{host = "h", port = 1}]}.

pick_id(Picker, Previous) ->
    {ok, #egrpc_pick_result{subchannel = Id}} =
        egrpc_picker:pick(Picker, #egrpc_pick_info{previous_subchannels = Previous}),
    Id.

rotation_test() ->
    {ok, S0} = init(#{}),
    {ok, Actions, S1} = update_endpoints([ep(a), ep(b), ep(c)], S0),
    ?assertMatch([{create_subchannel, _}, {connect, a} | _], Actions),
    ?assertEqual({error, no_ready_subchannel}, egrpc_picker:pick(picker(S1), #egrpc_pick_info{})),
    {ok, [], S2} = subchannel_state_changed(a, ready, S1),
    {ok, [], S3} = subchannel_state_changed(c, ready, S2),
    P = picker(S3),
    ?assertEqual([a, c, a, c], [pick_id(P, []) || _ <- lists:seq(1, 4)]),
    %% a subchannel which was used is avoided when there is another one
    ?assertEqual([c, c], [pick_id(P, [a]) || _ <- lists:seq(1, 2)]),
    %% and used when it is the only one
    {ok, [], S4} = subchannel_state_changed(c, transient_failure, S3),
    ?assertEqual(a, pick_id(picker(S4), [a])).

update_removes_test() ->
    {ok, S0} = init(#{}),
    {ok, _, S1} = update_endpoints([ep(a), ep(b)], S0),
    {ok, Actions, _} = update_endpoints([ep(b), ep(c)], S1),
    ?assertEqual([{remove_subchannel, a}, {create_subchannel, ep(c)}, {connect, c}], Actions).
-endif.
