%% @doc A logical call. It lives as long as all of its attempts, and it is what the
%% interceptors see: not a connection, not a subchannel.
%%
%% The accessors are the interface, the record is not.
-module(egrpc_call).

-include("egrpc_internal.hrl").

-export([new/3]).
-export([id/1, channel/1, grpc/1, method/1, service/1, type/1, metadata/1, put_metadata/3,
         set_metadata/2, deadline/1, remaining/1, wait_for_ready/1, retry_policy/1, attributes/1,
         put_attribute/3, info/1, opts/1, credentials/1, set_deadline/2]).

-export_type([call/0]).

-type call() :: #egrpc_call{}.

%% @private
%% The options of a call: `metadata', `timeout', `deadline', `with_metadata', `wait_for_ready',
%% `retry' (`false' or the options of the policy which are changed) and `attributes'.
-spec new(#egrpc_channel_ref{}, egrpc:grpc(), egrpc_client:opts()) -> call().
new(#egrpc_channel_ref{options = ChOpts, credentials = Credentials} = Channel, Grpc, Opts) ->
    #egrpc_call{
        id = make_ref(),
        channel = Channel,
        grpc = Grpc,
        metadata = egrpc_metadata:normalize(maps:get(metadata, Opts, #{})),
        credentials = Credentials,
        deadline = opts_deadline(Opts),
        wait_for_ready = maps:get(wait_for_ready, Opts, maps:get(wait_for_ready, ChOpts, false)),
        retry_policy = retry_policy(maps:get(retry, ChOpts, undefined), maps:get(retry, Opts, undefined)),
        attributes = maps:get(attributes, Opts, #{}),
        opts = maps:with([timeout, with_metadata], Opts)
    }.

%% The `deadline' option is relative, the call has an absolute time so that every attempt shares it.
opts_deadline(#{deadline_at := At}) -> At;
opts_deadline(#{deadline := Ms}) when is_integer(Ms), Ms >= 0 -> egrpc_deadline:from_timeout(Ms);
opts_deadline(_) -> infinity.

retry_policy(_Policy, false) -> undefined;
retry_policy(undefined, _) -> undefined;
retry_policy(Policy, undefined) -> Policy;
retry_policy(Policy, Override) when is_map(Override) -> maps:merge(Policy, Override).

-spec id(call()) -> reference().
id(#egrpc_call{id = Id}) -> Id.

-spec channel(call()) -> #egrpc_channel_ref{}.
channel(#egrpc_call{channel = Channel}) -> Channel.

-spec grpc(call()) -> egrpc:grpc().
grpc(#egrpc_call{grpc = Grpc}) -> Grpc.

%% @doc The method as in the path, `<<"/package.Service/Method">>'.
-spec method(call()) -> binary().
method(#egrpc_call{grpc = Grpc}) -> egrpc_method:path(Grpc).

-spec service(call()) -> atom().
service(#egrpc_call{grpc = Grpc}) -> egrpc_method:service(Grpc).

-spec type(call()) -> egrpc:grpc_type().
type(#egrpc_call{grpc = Grpc}) -> egrpc_method:type(Grpc).

-spec metadata(call()) -> [{binary(), binary()}].
metadata(#egrpc_call{metadata = Metadata}) -> Metadata.

%% @doc Add or replace an entry of the metadata of the call.
-spec put_metadata(binary(), binary(), call()) -> call().
put_metadata(Key, Value, #egrpc_call{metadata = Metadata} = Call) ->
    Call#egrpc_call{metadata = egrpc_metadata:store(Key, Value, Metadata)}.

-spec set_metadata(map() | [{binary(), binary()}], call()) -> call().
set_metadata(Metadata, #egrpc_call{} = Call) ->
    Call#egrpc_call{metadata = egrpc_metadata:normalize(Metadata)}.

%% @doc The deadline of the call, `infinity' or a time of `erlang:monotonic_time(millisecond)'.
-spec deadline(call()) -> egrpc_deadline:deadline().
deadline(#egrpc_call{deadline = Deadline}) -> Deadline.

-spec set_deadline(egrpc_deadline:deadline(), call()) -> call().
set_deadline(Deadline, #egrpc_call{} = Call) -> Call#egrpc_call{deadline = Deadline}.

%% @doc The milliseconds which are left of the deadline.
-spec remaining(call()) -> infinity | non_neg_integer().
remaining(#egrpc_call{deadline = Deadline}) -> egrpc_deadline:remaining(Deadline).

-spec wait_for_ready(call()) -> boolean().
wait_for_ready(#egrpc_call{wait_for_ready = W}) -> W.

-spec retry_policy(call()) -> undefined | map().
retry_policy(#egrpc_call{retry_policy = Policy}) -> Policy.

-spec attributes(call()) -> map().
attributes(#egrpc_call{attributes = Attrs}) -> Attrs.

%% @doc Keep something of the call for the interceptors which come after, or for the attempts.
-spec put_attribute(term(), term(), call()) -> call().
put_attribute(Key, Value, #egrpc_call{attributes = Attrs} = Call) ->
    Call#egrpc_call{attributes = Attrs#{Key => Value}}.

%% @doc The `info' of the channel.
-spec info(call()) -> term().
info(#egrpc_call{channel = Channel}) -> egrpc_channel:info(Channel).

%% @private
-spec opts(call()) -> map().
opts(#egrpc_call{opts = Opts}) -> Opts.

%% @private
-spec credentials(call()) -> undefined | egrpc_credentials:spec().
credentials(#egrpc_call{credentials = Credentials}) -> Credentials.
