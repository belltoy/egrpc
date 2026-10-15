%% @doc The picker: an immutable snapshot which the balancer publishes and the calls read, so a
%% pick never goes through the mailbox of the channel.
%%
%% A picker is built by `Module:picker/1' of the balancer, as `new(PickerModule, State)'.
%% `PickerModule' implements `pick/2', which is called in the process of the call. It chooses a
%% subchannel, and returns the `done' function which the attempt calls when it is over. It must
%% not block.
%%
%% `previous_subchannels' of the `#egrpc_pick_info{}' are the subchannels which the earlier
%% attempts of the call used: a picker avoids them when it has another one.
-module(egrpc_picker).

-include("egrpc_internal.hrl").

-export([new/2, failing/1, pick/2, default_done/0]).

-export_type([picker/0]).

-record(picker, {
    module :: undefined | module(),
    state :: term()
}).

-opaque picker() :: #picker{}.

-callback pick(State :: term(), #egrpc_pick_info{}) ->
    {ok, #egrpc_pick_result{}} | {error, Reason :: term()}.

-spec new(module(), term()) -> picker().
new(Module, State) ->
    #picker{module = Module, state = State}.

%% @doc A picker which fails every pick with `Reason', for a channel which has nothing to pick.
-spec failing(term()) -> picker().
failing(Reason) ->
    #picker{module = undefined, state = Reason}.

-spec pick(picker(), #egrpc_pick_info{}) -> {ok, #egrpc_pick_result{}} | {error, term()}.
pick(#picker{module = undefined, state = Reason}, _Info) ->
    {error, Reason};
pick(#picker{module = Module, state = State}, #egrpc_pick_info{} = Info) ->
    Module:pick(State, Info).

%% @doc The `done' of a picker which does not want the feedback.
-spec default_done() -> fun((#egrpc_pick_done{}) -> ok).
default_done() ->
    fun(_) -> ok end.
