%% @doc The status of a call. The calls themselves return `{grpc_error, Name, Message}' (see
%% `m:egrpc_error'); this module is the model of it for the parts of egrpc which need to reason
%% about the outcome of an attempt: the retry policy and the feedback of the picker.
-module(egrpc_status).

-include("egrpc_internal.hrl").

-export([new/2, from_error/1, to_error/1, code/1, name/1, is_ok/1]).

-export_type([status/0, code/0]).

-type status() :: #egrpc_status{}.
-type code() :: egrpc_error:grpc_error_name() | ok.

-spec new(code(), binary()) -> status().
new(Code, Message) ->
    #egrpc_status{code = Code, message = Message}.

-spec is_ok(status()) -> boolean().
is_ok(#egrpc_status{code = ok}) -> true;
is_ok(#egrpc_status{}) -> false.

%% @doc The status of the `Reason' of an `{error, Reason}' of a call. A failure of the transport
%% is `unavailable', a deadline is `deadline_exceeded', and anything else which is not a status
%% of the server is `unknown'. The reason is kept in `details'.
-spec from_error(term()) -> status().
from_error({grpc_error, Name, Message}) when is_atom(Name), is_binary(Message) ->
    #egrpc_status{code = Name, message = Message};
from_error(Reason) ->
    Code = case egrpc_error:class(Reason) of
        {transport, _} -> unavailable;
        {grpc, Name} -> Name;
        {local, _} -> unknown
    end,
    #egrpc_status{code = Code, message = iolist_to_binary(io_lib:format("~0p", [Reason])),
                  details = [Reason]}.

-spec to_error(status()) -> egrpc:grpc_error().
to_error(#egrpc_status{code = Code, message = Message}) ->
    {grpc_error, Code, Message}.

%% @doc The number of a code on the wire.
-spec code(code()) -> 0..16.
code(ok) -> 0;
code(canceled) -> 1;
code(unknown) -> 2;
code(invalid_argument) -> 3;
code(deadline_exceeded) -> 4;
code(not_found) -> 5;
code(already_exists) -> 6;
code(permission_denied) -> 7;
code(resource_exhausted) -> 8;
code(failed_precondition) -> 9;
code(aborted) -> 10;
code(out_of_range) -> 11;
code(unimplemented) -> 12;
code(internal) -> 13;
code(unavailable) -> 14;
code(data_loss) -> 15;
code(unauthenticated) -> 16.

-spec name(0..16) -> code().
name(0) -> ok;
name(1) -> canceled;
name(2) -> unknown;
name(3) -> invalid_argument;
name(4) -> deadline_exceeded;
name(5) -> not_found;
name(6) -> already_exists;
name(7) -> permission_denied;
name(8) -> resource_exhausted;
name(9) -> failed_precondition;
name(10) -> aborted;
name(11) -> out_of_range;
name(12) -> unimplemented;
name(13) -> internal;
name(14) -> unavailable;
name(15) -> data_loss;
name(16) -> unauthenticated.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

code_name_roundtrip_test() ->
    [?assertEqual(N, code(name(N))) || N <- lists:seq(0, 16)].

from_error_test() ->
    ?assertMatch(#egrpc_status{code = not_found}, from_error({grpc_error, not_found, <<"x">>})),
    ?assertMatch(#egrpc_status{code = unavailable}, from_error(timeout)),
    ?assertMatch(#egrpc_status{code = unavailable}, from_error({stream_error, closing})),
    ?assertMatch(#egrpc_status{code = unknown}, from_error({call_credentials, x})),
    ?assertEqual({grpc_error, internal, <<"m">>}, to_error(new(internal, <<"m">>))).
-endif.
