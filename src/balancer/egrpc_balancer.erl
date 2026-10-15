%% @doc The behaviour of the balancing policies.
%%
%% A balancer is a pure state machine, which the channel owns and calls. It decides which
%% subchannels exist, and which of them a call goes to by publishing pickers. It does not start
%% processes: it returns actions which the channel executes.
%%
%% `m:egrpc_balancer_pick_first' and `m:egrpc_balancer_round_robin' are the two of egrpc. A module
%% which implements this behaviour is the `balancer' option of `egrpc_channel:start/2', or
%% `{Module, Opts}' where `Opts' is given as `opts' of the config of `init/1'.
%%
%% The id of a subchannel is the id of its endpoint.
-module(egrpc_balancer).

-include("egrpc_internal.hrl").

-export([module/1, diff/2]).

-export_type([action/0, conn_state/0, strategy/0]).

-type conn_state() :: idle | connecting | ready | transient_failure | shutdown.

-type action() ::
    {create_subchannel, #egrpc_endpoint{}}
    | {remove_subchannel, SubchannelId :: term()}
    | {connect, SubchannelId :: term()}.

-type strategy() :: pick_first | round_robin | module() | {module(), term()}.

-callback init(Config :: map()) -> {ok, State :: term()}.

-callback update_endpoints([#egrpc_endpoint{}], State) -> {ok, [action()], State}.

-callback subchannel_state_changed(SubchannelId :: term(), conn_state(), State) ->
    {ok, [action()], State}.

-callback picker(State :: term()) -> egrpc_picker:picker().

%% @doc The module and the options of a strategy.
-spec module(strategy()) -> {module(), term()}.
module(pick_first) -> {egrpc_balancer_pick_first, undefined};
module(round_robin) -> {egrpc_balancer_round_robin, undefined};
module({Module, Opts}) when is_atom(Module) -> {Module, Opts};
module(Module) when is_atom(Module) -> {Module, undefined}.

%% @doc The ids which are not there any more or whose addresses changed (their subchannel is
%% removed), and the endpoints which are new or changed (they get a subchannel).
-spec diff(Old :: [#egrpc_endpoint{}], New :: [#egrpc_endpoint{}]) ->
    {Removed :: [term()], Added :: [#egrpc_endpoint{}]}.
diff(Old, New) ->
    OldMap = maps:from_list([{Id, A} || #egrpc_endpoint{id = Id, addresses = A} <- Old]),
    NewMap = maps:from_list([{Id, A} || #egrpc_endpoint{id = Id, addresses = A} <- New]),
    Removed = [
        Id || {Id, Addrs} <- maps:to_list(OldMap), maps:get(Id, NewMap, undefined) =/= Addrs
    ],
    Added = [
        E || #egrpc_endpoint{id = Id, addresses = Addrs} = E <- New,
             maps:get(Id, OldMap, undefined) =/= Addrs
    ],
    {lists:sort(Removed), Added}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

ep(Id, Port) ->
    #egrpc_endpoint{id = Id, addresses = [#egrpc_address{host = "h", port = Port}]}.

diff_test() ->
    A = ep(a, 1), B = ep(b, 2), C = ep(c, 3),
    ?assertEqual({[], []}, diff([A, B], [A, B])),
    ?assertEqual({[a], [C]}, diff([A, B], [B, C])),
    ?assertEqual({[b], [ep(b, 9)]}, diff([A, B], [A, ep(b, 9)])),
    ?assertEqual({[a, b], []}, diff([A, B], [])).
-endif.
