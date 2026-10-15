%% @doc Pick first: the calls go to the first ready subchannel in the order of the endpoints.
%%
%% Only one subchannel exists at first. The next one of the order is created when every one which
%% exists is in `transient_failure', so the first endpoint which can be reached is the one which is
%% used, and the first one is used again as soon as it is ready.
-module(egrpc_balancer_pick_first).

-behaviour(egrpc_balancer).
-behaviour(egrpc_picker).

-include("egrpc_internal.hrl").

-export([init/1, update_endpoints/2, subchannel_state_changed/3, picker/1]).
-export([pick/2]).

-record(state, {
    endpoints = [] :: [#egrpc_endpoint{}],
    %% The subchannels which exist, with their state.
    states = #{} :: #{term() => egrpc_balancer:conn_state()}
}).

init(_Config) ->
    {ok, #state{}}.

update_endpoints(New, #state{endpoints = Old, states = States0}) ->
    {Removed, _Added} = egrpc_balancer:diff(Old, New),
    States = maps:without(Removed, States0),
    Actions = [{remove_subchannel, Id} || Id <- Removed],
    {More, State} = progress(#state{endpoints = New, states = States}),
    {ok, Actions ++ More, State}.

subchannel_state_changed(Id, ConnState, #state{states = States} = State0) ->
    case maps:is_key(Id, States) of
        false ->
            {ok, [], State0};
        true ->
            {Actions, State} = progress(State0#state{states = States#{Id := ConnState}}),
            {ok, Actions, State}
    end.

%% Create the first subchannel, or the next one when every one is failing.
progress(#state{endpoints = Endpoints, states = States} = State) ->
    Uncreated = [E || #egrpc_endpoint{id = Id} = E <- Endpoints, not maps:is_key(Id, States)],
    Failing = lists:all(fun(S) -> S =:= transient_failure orelse S =:= shutdown end,
                        maps:values(States)),
    case Uncreated of
        [#egrpc_endpoint{id = Id} = E | _] when Failing ->
            {[{create_subchannel, E}, {connect, Id}], State#state{states = States#{Id => idle}}};
        _ ->
            {[], State}
    end.

picker(#state{endpoints = Endpoints, states = States}) ->
    Ready = [Id || #egrpc_endpoint{id = Id} <- Endpoints, maps:get(Id, States, idle) =:= ready],
    case Ready of
        [] -> egrpc_picker:failing(no_ready_subchannel);
        _ -> egrpc_picker:new(?MODULE, Ready)
    end.

%% @private
%% The first one which was not used, or the first when all were: a retry of a call goes on to the
%% next endpoint, and does not give up when there is only one.
pick(Ready, #egrpc_pick_info{previous_subchannels = Previous}) ->
    Id = case [I || I <- Ready, not lists:member(I, Previous)] of
        [First | _] -> First;
        [] -> hd(Ready)
    end,
    {ok, #egrpc_pick_result{subchannel = Id, done = egrpc_picker:default_done()}}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

ep(Id) ->
    #egrpc_endpoint{id = Id, addresses = [#egrpc_address{host = "h", port = 1}]}.

next_when_failing_test() ->
    {ok, S0} = init(#{}),
    {ok, Actions, S1} = update_endpoints([ep(a), ep(b)], S0),
    ?assertEqual([{create_subchannel, ep(a)}, {connect, a}], Actions),
    {ok, [], S2} = subchannel_state_changed(a, connecting, S1),
    {ok, Actions2, S3} = subchannel_state_changed(a, transient_failure, S2),
    ?assertEqual([{create_subchannel, ep(b)}, {connect, b}], Actions2),
    {ok, [], S4} = subchannel_state_changed(b, ready, S3),
    ?assertEqual({ok, b}, pick_of(S4)),
    %% the first is preferred again when it is ready
    {ok, [], S5} = subchannel_state_changed(a, ready, S4),
    ?assertEqual({ok, a}, pick_of(S5)).

pick_of(State) ->
    case egrpc_picker:pick(picker(State), #egrpc_pick_info{}) of
        {ok, #egrpc_pick_result{subchannel = Id}} -> {ok, Id};
        Error -> Error
    end.
-endif.
