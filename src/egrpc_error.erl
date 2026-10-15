-module(egrpc_error).

-export([from_grpc_status/1, class/1]).

-include_lib("egrpc/include/egrpc.hrl").

-export_type([
    grpc_error_name/0,
    grpc_error/0,
    class/0
]).

-type grpc_error_name() ::
      canceled
    | unknown
    | invalid_argument
    | deadline_exceeded
    | not_found
    | already_exists
    | permission_denied
    | resource_exhausted
    | failed_precondition
    | aborted
    | out_of_range
    | unimplemented
    | internal
    | unavailable
    | data_loss
    | unauthenticated.

-type grpc_error() :: {grpc_error, grpc_error_name(), Message :: binary()}.

%% What an error of a call is:
%% - `{grpc, Name}': the server answered with a status, or egrpc found the response invalid;
%% - `{transport, not_sent}': the request was not processed by the server, any method can be
%%   retried;
%% - `{transport, unknown}': the request may or may not have been processed;
%% - `{local, Reason}': an error of egrpc or of the application (the credentials, a hook), the call
%%   is not retried.
-type class() ::
    {grpc, grpc_error_name()}
    | {transport, not_sent | unknown}
    | {local, term()}.

-spec from_grpc_status(Headers) -> ok | {error, grpc_error()} when
    Headers :: [{binary(), binary()}].
from_grpc_status(Headers) ->
    Status = get_header(?GRPC_HEADER_STATUS, Headers, <<"0">>),
    Message = get_header(?GRPC_HEADER_MESSAGE, Headers, <<>>),
    case parse_status(Status) of
        ?GRPC_STATUS_OK -> ok;
        N when is_integer(N), N >= ?GRPC_STATUS_CANCELED, N =< ?GRPC_STATUS_UNAUTHENTICATED ->
            %% TODO: Handle grpc-status-details-bin
            {error, {grpc_error, error_name(N), Message}};
        _ -> {error, {grpc_error, error_name(?GRPC_STATUS_UNKNOWN), Message}}
    end.

%% @doc Classify the reason of an error of a call, `Reason' of `{error, Reason}'.
%%
%% The reasons are the ones which gun gives, as they are returned by the calls. A stream is not
%% processed by the server when it was refused (`refused_stream'), when it is above the last stream
%% id of a `GOAWAY' (`goaway'), or when gun refused to send it because the connection is closing
%% (`closing'): these are `not_sent'. A connection which was lost, a timeout and the other errors of
%% a stream may have been processed: these are `unknown'.
-spec class(term()) -> class().
class({error, Reason}) ->
    class(Reason);
class({grpc_error, Name, Message}) when is_atom(Name), is_binary(Message) ->
    {grpc, Name};
class({no_connection_available, _}) ->
    {transport, not_sent};
class({stream_error, {goaway, _, _}}) ->
    {transport, not_sent};
class({stream_error, {stream_error, refused_stream, _}}) ->
    {transport, not_sent};
class({stream_error, closing}) ->
    {transport, not_sent};
class({stream_error, _}) ->
    {transport, unknown};
class({connection_error, _}) ->
    {transport, unknown};
class({down, _}) ->
    {transport, unknown};
class(timeout) ->
    {transport, unknown};
class(Other) ->
    {local, Other}.

%% The status is a decimal number, may have more than one digit, e.g. `16'.
parse_status(Status) ->
    try binary_to_integer(Status)
    catch error:badarg -> invalid
    end.

-type value(T) :: T.
-spec get_header(binary(), [{binary(), binary()}], T) -> value(T).
get_header(Key, Headers, Default) ->
    %% eqwalizer:ignore
    proplists:get_value(Key, Headers, Default).

error_name(?GRPC_STATUS_CANCELED)            -> canceled;
error_name(?GRPC_STATUS_UNKNOWN)             -> unknown;
error_name(?GRPC_STATUS_INVALID_ARGUMENT)    -> invalid_argument;
error_name(?GRPC_STATUS_DEADLINE_EXCEEDED)   -> deadline_exceeded;
error_name(?GRPC_STATUS_NOT_FOUND)           -> not_found;
error_name(?GRPC_STATUS_ALREADY_EXISTS)      -> already_exists;
error_name(?GRPC_STATUS_PERMISSION_DENIED)   -> permission_denied;
error_name(?GRPC_STATUS_RESOURCE_EXHAUSTED)  -> resource_exhausted;
error_name(?GRPC_STATUS_FAILED_PRECONDITION) -> failed_precondition;
error_name(?GRPC_STATUS_ABORTED)             -> aborted;
error_name(?GRPC_STATUS_OUT_OF_RANGE)        -> out_of_range;
error_name(?GRPC_STATUS_UNIMPLEMENTED)       -> unimplemented;
error_name(?GRPC_STATUS_INTERNAL)            -> internal;
error_name(?GRPC_STATUS_UNAVAILABLE)         -> unavailable;
error_name(?GRPC_STATUS_DATA_LOSS)           -> data_loss;
error_name(?GRPC_STATUS_UNAUTHENTICATED)     -> unauthenticated.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

from_grpc_status_test() ->
    Err = fun(S) -> from_grpc_status([{?GRPC_HEADER_STATUS, S}, {?GRPC_HEADER_MESSAGE, <<"m">>}]) end,
    ?assertEqual(ok, from_grpc_status([])),
    ?assertEqual(ok, Err(<<"0">>)),
    ?assertEqual({error, {grpc_error, invalid_argument, <<"m">>}}, Err(<<"3">>)),
    %% Two-digit statuses must not fall back to `unknown'.
    ?assertEqual({error, {grpc_error, aborted, <<"m">>}}, Err(<<"10">>)),
    ?assertEqual({error, {grpc_error, out_of_range, <<"m">>}}, Err(<<"11">>)),
    ?assertEqual({error, {grpc_error, unavailable, <<"m">>}}, Err(<<"14">>)),
    ?assertEqual({error, {grpc_error, unauthenticated, <<"m">>}}, Err(<<"16">>)),
    %% Out of range or malformed statuses are `unknown'.
    ?assertEqual({error, {grpc_error, unknown, <<"m">>}}, Err(<<"17">>)),
    ?assertEqual({error, {grpc_error, unknown, <<"m">>}}, Err(<<"-1">>)),
    ?assertEqual({error, {grpc_error, unknown, <<"m">>}}, Err(<<"abc">>)),
    ok.

class_test() ->
    %% the server answered
    ?assertEqual({grpc, unavailable}, class({grpc_error, unavailable, <<"x">>})),
    ?assertEqual({grpc, internal}, class({error, {grpc_error, internal, <<>>}})),
    %% not processed by the server
    ?assertEqual({transport, not_sent},
                 class({stream_error, {goaway, no_error, 'The connection is going away.'}})),
    ?assertEqual({transport, not_sent},
                 class({stream_error, {stream_error, refused_stream, 'Stream reset by server.'}})),
    ?assertEqual({transport, not_sent}, class({stream_error, closing})),
    ?assertEqual({transport, not_sent}, class({no_connection_available, no_ready})),
    %% may have been processed
    ?assertEqual({transport, unknown}, class({stream_error, closed})),
    ?assertEqual({transport, unknown}, class({stream_error, {closed, einval}})),
    ?assertEqual({transport, unknown},
                 class({stream_error, {stream_error, cancel, 'Stream reset by server.'}})),
    ?assertEqual({transport, unknown}, class({connection_error, {closed, normal}})),
    ?assertEqual({transport, unknown}, class({down, noproc})),
    ?assertEqual({transport, unknown}, class(timeout)),
    ?assertEqual({transport, unknown}, class({error, timeout})),
    %% of egrpc or of the application
    ?assertEqual({local, {call_credentials, no_token}}, class({call_credentials, no_token})),
    ?assertEqual({local, client_not_found}, class(client_not_found)),
    ?assertEqual({local, foo}, class(foo)).

%% Every status of the gRPC status code table maps to its name, the message is optional.
status_names_test() ->
    Names = [
        canceled, unknown, invalid_argument, deadline_exceeded, not_found, already_exists,
        permission_denied, resource_exhausted, failed_precondition, aborted, out_of_range,
        unimplemented, internal, unavailable, data_loss, unauthenticated
    ],
    lists:foreach(
        fun({Status, Name}) when is_integer(Status) ->
            Headers = [{?GRPC_HEADER_STATUS, integer_to_binary(Status)}],
            ?assertEqual({error, {grpc_error, Name, <<>>}}, from_grpc_status(Headers))
        end,
        lists:zip(lists:seq(1, 16), Names)
    ),
    %% The message is ignored when the status is OK.
    ?assertEqual(ok, from_grpc_status([{?GRPC_HEADER_STATUS, <<"0">>},
                                       {?GRPC_HEADER_MESSAGE, <<"ignored">>}])).
-endif.
