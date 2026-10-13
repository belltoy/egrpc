-module(egrpc_error).

-export([from_grpc_status/1]).

-include_lib("egrpc/include/egrpc.hrl").

-export_type([
    grpc_error_name/0,
    grpc_error/0
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
-endif.
