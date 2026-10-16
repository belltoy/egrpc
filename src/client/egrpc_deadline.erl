%% @doc The deadline of a logical call: an absolute time of the monotonic clock in milliseconds,
%% so that all the attempts of the call share it.
-module(egrpc_deadline).

-export([from_timeout/1, remaining/1, expired/1, header/1]).

-export_type([deadline/0]).

-type deadline() :: infinity | integer().

%% @doc The deadline which is `Ms' from now.
-spec from_timeout(undefined | infinity | non_neg_integer()) -> deadline().
from_timeout(undefined) -> infinity;
from_timeout(infinity) -> infinity;
from_timeout(Ms) when is_integer(Ms), Ms >= 0 -> erlang:monotonic_time(millisecond) + Ms.

%% @doc The milliseconds which are left, `infinity' without a deadline. Not below 0.
-spec remaining(deadline()) -> infinity | non_neg_integer().
remaining(infinity) -> infinity;
remaining(At) -> left(At).

%% erlang:max/2 is typed on any term, this one keeps the integer.
-spec left(integer()) -> non_neg_integer().
left(At) ->
    case At - erlang:monotonic_time(millisecond) of
        Ms when Ms > 0 -> Ms;
        _ -> 0
    end.

-spec expired(deadline()) -> boolean().
expired(infinity) -> false;
expired(At) -> At - erlang:monotonic_time(millisecond) =< 0.

%% @doc The `grpc-timeout' header of what is left, `undefined' without a deadline.
-spec header(deadline()) -> undefined | binary().
header(infinity) -> undefined;
header(At) -> egrpc_grpc:timeout_header(left(At)).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

deadline_test() ->
    ?assertEqual(infinity, from_timeout(undefined)),
    ?assertEqual(infinity, remaining(infinity)),
    D = from_timeout(1000),
    ?assert(remaining(D) =< 1000 andalso remaining(D) > 900),
    ?assertNot(expired(D)),
    ?assert(expired(from_timeout(0))),
    ?assertEqual(0, remaining(from_timeout(0))),
    ?assertEqual(undefined, header(infinity)),
    ?assertMatch(<<_, _/binary>>, header(D)).
-endif.
