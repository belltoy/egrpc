# egrpc refactoring plan

Status: implemented on the branch `refactor`, see "Phase 0 status" and "Phase 1 status". Section 8
lists the decisions; there are no open questions. What is not done is listed in "Phase 1 status".

This is a **breaking change**. Backward compatibility with 0.1.x is explicitly not a goal: old options
are removed, not deprecated.

## 1. Background

While adapting etcdgun to etcd 3.6 and 3.7 authentication, several limitations in egrpc's channel and
interceptor design showed up. etcdgun had to add a number of workarounds (see section 7), and those
workarounds are really compensating for capabilities egrpc does not have.

The goal of this plan is to provide those capabilities in egrpc, so applications no longer need the
workarounds.

## 2. Current state

Based on v0.1.2, from reading `egrpc_stub` and `egrpc_stream`.

### 2.1 Channel

The `#channel{}` record in `egrpc_stub`:

```erlang
-record(channel, {
    host, port, codec,
    unary_interceptors = [],     %% [fun/4]
    stream_interceptors = [],    %% [{Module, InitState}]
    conn_pid,                    %% the gun connection
    headers = [],
    opts                         %% conn_opts() given to open/3, `info' is user data
}).
```

- It holds both the connection handle (`conn_pid`, `host`, `port`) and the call pipeline
  (interceptors, `info`).
- The record is defined inside `egrpc_stub.erl`. Outside the module there are only getters and
  `set_info/2`; there is no way to derive a channel with a different pipeline.
- `opts` keeps the whole map given to `open/3`, including the interceptor lists, so the lists exist
  twice (in the record fields and in `opts`).
- `headers` is never set or read in `egrpc_stub` and `egrpc_stream` (elp reports `W0003`, unused
  record field, for both `channel.headers` and `stream.headers`). It is removed together with the
  record split.
- The codec is hard-coded to `egrpc_proto` in `open/3`, and the `content-type` request header is
  hard-coded to `application/grpc+proto` in `egrpc_stream`, so another codec would still announce
  protobuf.
- A stream (`#stream{}`) holds a copy of the channel value taken in `egrpc_stream:new/2`. It has its own
  `info`, which is not inherited from the channel.

### 2.2 Interceptors

| | Unary | Streaming |
|---|---|---|
| Form | `fun(Stream, Req, Opts, Next)`, no state, no init | `egrpc_stream_interceptor` behaviour with 6 optional hooks |
| Execution | wrapped with `foldl` in `egrpc_stream:unary/3`, runs synchronously in the caller process | the chain is built per stream in `egrpc_stream:new/2`, the state travels with the stream value |
| Scope | wraps the whole call | hooks for individual phases only, nothing wraps the whole call |

- **They are disjoint by RPC type.** `init_stream_interceptors` returns `{undefined, #{}}` for unary
  RPCs, so streaming interceptors never see unary calls, and unary interceptors never see streaming
  calls. One concern (such as authentication) has to be written twice.
- The state of streaming interceptors is kept in a map keyed by **module name**. Configuring the same
  module twice makes the entries collapse into one.
- The order is `foldl`: the first element of the list is the innermost, the last is the outermost.
  This is not documented.
- `open/3` silently drops invalid elements of `stream_interceptors` with `filtermap`. The arity of a
  unary interceptor is only checked when the call is made.

### 2.3 Per-call options and timeouts

- `egrpc_stub:opts()` only has `metadata`.
- The unary response timeout is hard-coded to 5000 ms and is given to each of `recv_header`,
  `recv_msg` and the trailers read in turn, so the worst case is longer than 5000 ms.
- On timeout the stream is not cancelled. By reading the code (not verified by running), a late
  response is left in the mailbox of the caller process.

### 2.4 Other findings

- In the unary path, `Next0` discards the stream returned by `send_msg`, and `recv_response` returns
  only `{ok, Resp}`, so the final stream (and the state of the hooks) is lost.
- In `recv_response`, when `Rest` is not `<<>>` the `?=` pattern does not match and the `else` clause
  returns `{ok, Stream, Resp, Rest}` as the call result, which does not conform to the spec.
- `recv_msg0` has no `{trailers, _}` clause, so a streaming response which ends normally would
  raise `case_clause` (not verified by running). Streaming callers are expected to drive `gun:await`
  themselves and use `parse_msg/2`. egrpc never observes the end of a streaming call.
- There is no `test/` directory and no tests. The README does not mention interceptors.

## 3. Problems and goals

| # | Problem | Consequence | Goal |
|---|---|---|---|
| P1 | The connection and the pipeline are one value, the pipeline can not be derived | To make a call that bypasses the user's interceptors on the same connection, the application has to open another connection | Derive channels with a different pipeline that share the connection |
| P2 | No per-call credentials | Applications put the token into `info`, rewrite it every time they hand out a channel, and let an interceptor read it back and call into the application | A first-class per-RPC credentials mechanism |
| P3 | Two interceptor mechanisms, disjoint by RPC type | One concern has to be written as two modules | One mechanism where every interceptor sees every call |
| P4 | Poor per-call options | The timeout is hard-coded | Make the timeout an option |
| P5 | `info` is used as dynamic context | An untyped bag with unclear semantics | `info` is only for static channel-level data |
| P6 | Usability: silent dropping, surprising order, late validation | A wrong configuration gives no feedback | Validate in `open/3` and `derive/2`, define the order |
| P7 | The codec is not configurable, `content-type` is hard-coded | Other codecs announce the wrong content type | The codec is an `open/3` option and provides its own content type |
| P8 | No tests, no documentation | No safety net for refactoring | Add tests and documentation first |

Non-goals:

- Backward compatibility with 0.1.x.
- Changing the gRPC protocol implementation (frame encoding/decoding, how gun is used).
- Adding processes or a connection pool. egrpc keeps the model where the caller owns the channel value.
- Redesigning the streaming receive path, and a "call end" hook (see 4.6).
- Changing etcdgun as part of this plan.

## 4. Design

### 4.1 Pipeline and `derive/2` (P1, P5)

The **pipeline** is the configurable layer a call goes through, as opposed to the connection:
interceptors, call credentials and `info`. `host`, `port`, `conn_pid`, `gun_opts` and `retry` belong to
the connection.

```erlang
-type pipeline_opts() :: #{
    interceptors     => [interceptor()],
    call_credentials => call_credentials() | undefined,
    info             => term()
}.

%% Return a channel which shares the connection but has a different pipeline.
-spec derive(channel(), pipeline_opts()) -> channel().
```

- A key which is present **replaces** the corresponding setting, a key which is absent keeps it.
  Clearing is explicit: `interceptors => []`, `call_credentials => undefined`.
- The keys and formats are the same as the corresponding options of `open/3`. The normalization
  of `open/3` is extracted into an internal function used by both.
- `derive/2` raises `error(...)` for invalid input: an unknown key, a connection-level key
  (`gun_opts`, `retry`, ...), or an invalid interceptor spec. Exceptions raised by the `init/1` of an
  interceptor are not caught.
- Only a new record value is built, the connection is untouched. `conn_pid`, `host` and `port` do not
  change, and no gun connection is opened.
- Streaming interceptors go through `init/1` again for the derived channel, and their state is
  independent of the original.
- `codec` is not part of `pipeline_opts()`. A derived channel keeps the codec of the original.
- A stream copies the channel when it is created, so a derived channel only affects streams created
  after the derivation.

Removed: `egrpc_stub:set_info/2` (use `derive(Ch, #{info => Info})`) and the previously planned
`without_interceptors/1` (use `derive(Ch, #{interceptors => []})`). The getters (`info/1,2`, `host/1`,
`port/1`, `conn_pid/1`, `codec/1`) stay. `egrpc_stream:info/1,2` and `egrpc_stream:set_info/2` are
per-stream and stay.

**Closing the connection.** A channel has a `closable` flag. The value returned by `open/3` is
closable, every value returned by `derive/2` is not. `close/1,2` on a value which is not closable
raises `error(not_closable)`. (This is unrelated to the owner process of the gun connection, which is
the process which called `open/3`.) This keeps a view which was handed out to a third party from closing the shared
connection. The consequence is that whoever opened the channel must keep the original value.

`info` is documented as "channel-level data set when the channel is created or derived". Data which
changes per call does not go there.

The internal representation can be split along the same line, for example:

```erlang
-record(conn,     {host, port, conn_pid}).
-record(pipeline, {interceptors, chain, call_credentials, info}).
-record(channel,  {conn, codec, pipeline, closable}).
```

The record layout is an implementation detail. The public `channel()` type name and the getters stay.

### 4.2 Per-call credentials (P2)

A channel-level credentials callback, given to `open/3` and `derive/2` as `call_credentials`:

```erlang
-type call_credentials() ::
    fun((egrpc:stream()) -> {ok, #{binary() => binary()}} | {error, term()}).
```

- It is called before every call is sent, in `egrpc_stream:init_req0`. This is the common end point of
  unary and streaming calls and sits below all the interceptors, so both kinds are covered by one
  implementation.
- The returned metadata is merged into the request headers, and goes through the same `grpc-` prefix
  filter as the call options. Metadata given in the call options takes precedence.
- If it returns `{error, Reason}`, the call fails without being sent, with
  `{error, {call_credentials, Reason}}`. This needs the `init_req` chain to be able to return errors
  (see 4.3).
- It runs in the caller process, like unary interceptors. It should be fast and side-effect free; it
  reads a token maintained by the application. It receives the stream so that it can decide by
  service and method. It does not receive the call `Opts`: a call overrides the credentials with
  `metadata`, and the other call options are not related to credentials.
- **Exceptions are not caught.** An exception raised by the callback is a bug of the callback and
  propagates like the exceptions of interceptors, so the calling process fails. Nothing has been sent
  and the connection is not affected, unless the calling process is the owner of the gun connection
  (the connection is closed when its owner exits). "No token yet" is an expected failure and is
  returned as `{error, Reason}`.
- **The shape of the return value is checked.** Anything which is neither `{ok, Map}` (with
  `is_map(Map)`) nor `{error, _}` raises `error({invalid_call_credentials, Ret})`. The keys and
  values of the map are not checked.
- It is called for **every call**, including when an interceptor calls `Next` again for a retry. For a
  streaming call it is called once, when the stream is opened; egrpc can not update the credentials of
  a stream which is already open, so an application has to open a new stream when the token of a
  long-lived stream expires.
- Refreshing is **not** part of egrpc. Re-authenticating and retrying after a token becomes invalid is
  application semantics and is done by an interceptor, which calls `Next` again; the callback is
  called again and sees the refreshed token.

With this, applications do not need to pass the token through `info`, and the circular dependency
between the interceptor and the application goes away. What is left for an interceptor is only the
retry.

### 4.3 Interceptors (P3, P6)

One mechanism. The old `unary_interceptors` and `stream_interceptors` options are removed, and
`egrpc_stream_interceptor` is replaced by a new behaviour (working name `egrpc_interceptor`) without
an alias.

```erlang
-callback init(InitOpts :: term()) -> State :: term().

%% Wraps a whole unary call.
-callback unary(Stream, Req, Opts, Next, State) -> Result when
    Next   :: fun((Stream, Req, Opts) -> Result),
    Result :: {ok, map()} | {error, term()}.

%% Phase hooks. They fire for all call types, unary included.
-callback init_req(Stream, Opts, Next, State)         -> hook_ret().
-callback send_msg(Stream, Req, IsFin, Next, State)   -> hook_ret().
-callback recv_header(Stream, Timeout, Next, State)   -> hook_ret().
-callback recv_msg(Stream, Timeout, Buf, Next, State) ->
    {ok, {Stream, State}, Resp, Rest} | {error, term()}.

%% Streaming only.
-callback close_send(Stream, Next, State)             -> hook_ret().
-callback parse_msg(Stream, Buf, Next, State)         ->
    more | {ok, {Stream, State}, Resp, Rest} | {error, term()}.

-type hook_ret() :: {ok, {Stream, State}} | {error, term()}.
```

All callbacks are optional.

Configuration: `open(H, P, #{interceptors => [Module | {Module, InitOpts} | fun/4]})`.

- **Return shape.** All the hooks return `{ok, {Stream, State}}` (or the `recv_msg`/`parse_msg`
  variants) or `{error, Reason}`. In the old behaviour `init_req`, `send_msg` and `close_send` returned
  a bare `{Stream, State}` and had no way to fail. An `{error, _}` is the result of the call; the call
  is not sent and the inner layers are not entered.
- **Order.** The first element of the list is the outermost.
- **Wraps and hooks.** All the `unary/5` wraps are outside, all the hooks run inside the innermost
  `Next0`. For `[A, B]`: `A:unary → B:unary → Next0 → A:init_req → B:init_req → init_req0`.
- **A unary call is a degenerate stream.** The hooks fire as follows:

  | Hook | In a unary call |
  |---|---|
  | `init_req` | once, before sending; headers are added by changing `metadata` in `Opts` |
  | `send_msg` | once, with `IsFin = fin` |
  | `recv_header` | once |
  | `recv_msg` | once, with `Buf = <<>>`; `Rest` must be `<<>>`, otherwise it is an error |
  | `close_send`, `parse_msg` | never |

- **State.** The `State` given to a hook is threaded through the hooks of one call and lives in the
  stream. The `State` given to `unary/5` is the result of `init/1`, read-only. The wrap and the hooks do
  not share state; a wrap which needs "before" and "after" uses local variables. `State` is kept in
  `unary/5` because a module interceptor gets its configuration (`InitOpts`) through `init/1`; the
  documentation must say that a wrap can not change the state, only the hooks can.
- **`Result` is unchanged:** `{ok, Resp} | {error, term()}`. It does not carry response headers or
  trailers, because it is the public return value of the generated clients (`unary_ret/1`) and there
  is no known user. A consequence of `Next` returning only `Result` is that a wrap never sees the
  final stream.
- **State is keyed by position** in the `interceptors` list, not by module name, so the same module can
  be configured more than once with independent state.
- **`fun/4`** stays valid in the list as a shorthand: it is a stateless interceptor which only
  implements `unary/5` (without `State`). It does not see streaming calls.
- **The chain is built once**, when the pipeline is built in `open/3` or `derive/2`, not for every
  stream. The chain only depends on the list of interceptors (the state is looked up at runtime), so
  `derive/2` rebuilds it when `interceptors` is given and keeps it otherwise.
- **Validation.** `open/3` and `derive/2` check every element. An element which is neither a `fun/4`
  nor a module implementing the behaviour is an error, never dropped silently.
- **Removed options.** `open/3` raises `error({removed_option, Key})` when it receives
  `unary_interceptors` or `stream_interceptors`, the same way `derive/2` raises for invalid input.
- **Required fix in the unary path.** `Next0` must thread the stream through `send_msg` and
  `recv_response` must return the final stream, otherwise the hook state is lost. The `Rest` check
  in `recv_response` becomes an explicit error.

### 4.4 Codec (P7)

- `open/3` gets a `codec` option, a module implementing `egrpc_codec`, default `egrpc_proto`. It is
  validated in `open/3`. It is **not** part of `derive/2`.
- `egrpc_codec` gets a required callback `content_type/0 -> binary()`. The built-in codecs return their
  own value, and `init_req0` uses the value of the channel's codec instead of the hard-coded
  `application/grpc+proto`.
- `grpc-encoding` stays hard-coded to `identity`; compression is out of scope.
- The codec option has no place for user options yet: `init/1` receives the `Grpc` map of the call.
- **`egrpc_json` is fixed in this change.** Today it can not send a message: the encoder returns the
  map which the generated `to_json/2` returns, not JSON text, and the decoder would need to be given
  a term, not the bytes of the response (found by the tests of phase 0, see "Phase 0 status"). It is
  fixed together with `content_type/0`, because `application/grpc+json` is what the codec announces.
  Decided: the minimum OTP version of egrpc is 27 and the codec uses the `json` module of OTP
  (`rebar.config` gets `{minimum_otp_vsn, "27"}`). Still to see when fixing: how to test it against a
  server which accepts `application/grpc+json`, as GripMock may not; the fake server can answer with
  JSON text to test the client side.

### 4.5 Per-call options (P4)

`opts()` gets a `timeout :: timeout()` option for the unary response timeout, replacing the
hard-coded 5000 ms.

- **Semantics are unchanged:** the value is the timeout of every single wait for a gun message
  (response headers, each data frame, trailers). It is not a deadline for the whole call. The default
  stays 5000 ms. There is no channel-level default; an application which wants one can set `timeout`
  in `Opts` from an interceptor.
- **No `grpc-timeout` header** is sent. The timeout is only a local limit on waiting, the server is
  not told and keeps processing the request.
- **Unary only.** The `Timeout` of the streaming `recv_header`/`recv_msg` is given by the caller on
  every call and has the same per-wait meaning.
- `egrpc_stub:await_up/2` takes a `Timeout`; `await_up/1` is `await_up(Channel, 5000)`.

Cleanup of the stream when a unary call fails (`egrpc_stream:recv_unary_response/2`):

| Result | Action |
|---|---|
| success | none |
| gRPC status error (trailers received) | none; gun has already deleted the stream, a `gun:cancel` would only make gun send a `gun_error` (`"The stream cannot be found."`) to the caller |
| timeout, transport error, error of a hook | `cancel_and_flush`: `gun:cancel`, a synchronous call to the connection, `gun:flush(StreamRef)` |
| error found locally (decode failure, unsupported compression, invalid compressed flag, unexpected frame) | the same `cancel_and_flush` |

**The rule changed while it was implemented.** It was decided that an error found locally is only
flushed, not cancelled. The test `no_leftover_after_decode_failure` showed that this is not enough:
the trailers of the response are still on their way when the error is found, and they arrive after
the flush. `gun:cancel/2` is asynchronous, so it is followed by a call to the connection process
(`gun:stream_info/2`): gun replies after it handled the cancel, and every message of the stream which
it sent before is in the mailbox when the call returns, the `gun_error` of a cancel of a stream which
is already finished included. The flush then removes all of them, without a race.

A server which keeps sending data in a unary call after an error is cancelled with the stream.

Local decode errors are reported as `INTERNAL` (the separate fix `fix: report response decode
failures as INTERNAL`), as the gRPC status code table requires for a client.

**Verified by running** (`test/egrpc_gun_SUITE.erl` and `test/egrpc_unary_SUITE.erl`, gun 2.x,
against the fake server):

- `gun:cancel` on a stream which has finished makes gun send
  `{gun_error, Conn, StreamRef, {badstate, "The stream cannot be found."}}` to the caller.
- `gun:cancel` followed by `gun:flush(StreamRef)` on a live stream: nothing of the stream is delivered
  afterwards, the late response of the server does not reach the mailbox (observed for 2.5 s).
- `gun:flush(StreamRef)` removes the unread messages of a stream (the three messages of a complete
  response).
- Through egrpc, nothing of the stream is left in the mailbox after a status error, a decode
  failure, an unsupported compression and a timeout (`no_leftover_*`, repeated 6 times without a
  failure).

### 4.6 Decided not to do

- **A "call end" hook.** Unary calls can use the wrap of `unary/5` for tracing, metrics and counters.
  For streaming calls egrpc does not observe the end of the call (section 2.4), and adding that means
  redesigning the streaming receive path. There is no concrete user for it. Where a streaming caller
  needs these, it does it where it drives the stream.
- **`ctx`** (call context passed to interceptors). Unary interceptors and `init_req` already receive
  `Opts`. Postponed until there is a real need.
- **Response headers and trailers in the result.** Candidate for later, not part of this change: keep
  the response headers in `#stream{}` (`recv_header0` drops them today) and add
  `egrpc_stream:response_headers/1`. Trailers need the end of the call to be observable first.
- **A `user-agent` request header.** Candidate for later, not part of this change. egrpc does not send
  one; the gRPC HTTP/2 protocol document lists it as optional and recommends
  `grpc-<language>[-<variant>]/<version>` (for example `grpc-erlang-egrpc/<vsn>`). The version should
  be read at runtime from the `vsn` of the application, not hard-coded.

## 5. Phases

| Phase | Content |
|---|---|
| 0 | Test infrastructure and characterization tests of the parts which do not change |
| 1 | The breaking change: record split and `derive/2`, unified interceptors, `call_credentials`, codec and `content-type` (with the `egrpc_json` fix), validation, `timeout`, documentation |

Phase 1 is released as one breaking release in the 0.2.x series (0.2.0 is the first). Cutting the
release is the maintainer's job. The work inside phase 1 can
be done in this order: record split, `derive/2` and `closable`, unified interceptors with the unary fixes,
`call_credentials`, codec.

### Phase 0: test infrastructure

egrpc has no tests at all, so refactoring can not start directly. egrpc is a general-purpose gRPC
client library, so the test suite must not depend on one particular server (such as etcd). Four
layers:

1. **Pure logic tests (eunit, no network):**
   - Unary interceptor chain: build a fake `Next`, assert the execution order, the rewriting of
     `Opts`/`Req`, and the propagation of errors.
   - Streaming interceptor chain: use a fake stream value, assert the order of the hooks and the state
     passing.
   - `egrpc_error:from_grpc_status/1` (there is already an inline test; complete it for statuses 0-16
     and malformed values).
   - The normalization of `open/3` (testable once extracted as a pure function).
2. **An in-process fake server (Common Test, no docker):** a test-only server on cowboy (HTTP/2 over
   plain TCP), which controls the exact bytes and the timing of the response. It covers what a real
   server never does:
   - local errors: a message which fails to decode, a compressed flag of 1 with an unsupported
     encoding, an invalid compressed flag, an unexpected `END_STREAM` on a data frame, a missing
     trailers frame;
   - a trailers-only error response;
   - a timeout (the server does not reply) and a transport error (the server closes the socket);
   - the stream cleanup rules of 4.5, **checked here by running**: what is left in the caller's
     mailbox after a timeout, a status error and a local error, and what `gun:cancel` does on a
     stream which is already finished.

   Whether cowboy can send arbitrary frames and control `END_STREAM` and the trailers precisely has
   to be tried first; if it can not, the fake server is a minimal HTTP/2 server written in the tests.
3. **GripMock (`bavix/gripmock`, Common Test, docker or the binary):** an independent gRPC server
   implementation (grpc-go). It checks that egrpc interoperates with a server which does not share
   egrpc's understanding of the protocol: the four kinds of RPC, status errors, request metadata and
   credentials (through its history and verify API). It needs a test `.proto` with all four kinds of
   RPC (the protos of egrpc have no client streaming one); the pb module and the client for it are
   generated in the test profile. GripMock only sends well-formed gRPC, so it does not replace
   layer 2. The syntax of its delay and trailers has to be checked by running.
4. **A real server (optional):** an etcd container (`quay.io/coreos/etcd`) for scenarios where a real
   server is useful: `grpc.health.v1.Health.Check`, `Watch`, and authentication, whose per-version
   differences (which RPCs need a token) are known. It is a regression aid for etcdgun, not a
   prerequisite of the suite.

Every external requirement (docker, the GripMock binary or image, the etcd image) is checked on its
own and only its group is skipped when it is missing. `rebar3 eunit` needs none of them, and the fake
server group needs only cowboy.

The characterization tests should only pin down what survives the refactoring: encoding and decoding,
framing, error mapping and the transport behaviour of a unary call. The old interceptor behaviour is
replaced and is not worth pinning.

#### Phase 0 status

Layers 1, 2 and 3 are in place (`rebar3 eunit`: 9 tests, `rebar3 ct`: 23 tests, all passing on the
code of 0.1.2 plus the `INTERNAL` fix). Layer 4 (etcd) is not written.

What running them showed:

- cowboy 2.12.0 serves HTTP/2 over plain TCP when `protocols => [http2]` (prior knowledge), and gun
  and egrpc connect to it without any TLS. cowboy sends trailers only to a request which has
  `te: trailers`. cowboy 2.13.0 can not be fetched with rebar3 3.25.1 (`Dep ranch has invalid
  version`), so 2.12.0 is pinned.
- GripMock (`bavix/gripmock`, v3.23.3 when tried) interoperates with egrpc for all four kinds of RPC,
  status errors (`output.error` and `output.code`), request header matching (`headers.equals`),
  response delay (`output.delay`), server streams (`output.stream`), client streams (`inputs`) and
  bidirectional streams (every incoming message is matched on its own with `input`, `contains` is a
  subset match, not a substring match).
- The end of a streaming call can be read from gun only, as described in 2.4.
- **`egrpc_json` does not work:** the generated `to_json/2` returns a map, not text, so the encoder
  returns a map where a binary is needed. It is noted in the module and not fixed here.
- The local-error cases (decode failure, unsupported compression, invalid compressed flag, data frame
  with `END_STREAM`) are reported as `INTERNAL` by the fix of `egrpc_grpc`; a `END_STREAM` on the
  data frame of a complete message is an error even though the message is whole.
- Today, after a decode failure the trailers are left in the mailbox, and after a timeout the late
  response reaches it (`leftover_after_decode_failure`, `leftover_after_timeout`).

### Phase 1 acceptance

- **`derive/2`:** the derived channel has the same `conn_pid/1` as the original; a request on it only
  goes through its own interceptors and the original is not affected; `init/1` of interceptors is
  called for the derived channel with independent state; invalid input raises; `close/1,2` on it
  raises `not_closable`.
- **Interceptors:** all the hooks fire in a unary call as in the table of 4.3; wraps are outside and
  hooks inside; the first element is the outermost; the same module configured twice has independent
  state; a hook returning `{error, _}` stops the call.
- **`call_credentials`:** the returned metadata is in the request, and call-level `metadata` takes
  precedence; when the callback returns `{error, _}` the call is not sent; a retry from an interceptor
  calls the callback again; a return value of the wrong shape raises `invalid_call_credentials`.
- **Codec:** the `content-type` header comes from the codec; a message encoded by `egrpc_json` is a
  binary of JSON text and decodes back to the same message.
- **Timeout:** `timeout` in `Opts` is used for every wait of a unary call; after a timeout or a
  transport error the stream is cancelled and the mailbox has no message of it; after a local error
  the mailbox has no message of it; after a status error nothing is sent to gun.

### Phase 1 status

Steps 1 to 7 of the order above are implemented, each in its own commits, with tests: 21 eunit tests
and 39 Common Test cases, line coverage 92% (`rebar3 do eunit, ct, covertool generate`). The
acceptance conditions above are covered by `egrpc_stub_SUITE` and the inline tests of `egrpc_stub`
(`derive/2`), `egrpc_interceptor_SUITE` (interceptors), `egrpc_call_credentials_SUITE`,
`egrpc_codec_SUITE`, and `egrpc_unary_SUITE` (timeout and the cleanup).

Where the implementation differs from the text of the plan:

- The cleanup of a failed call: `cancel` + a call to the connection + `flush` for local errors too,
  see 4.5.
- `egrpc_stream:send_msg/3` and `close_send/1` return `{ok, Stream} | {error, Reason}`, because a
  hook can fail. `egrpc_stream_interceptor` is replaced by `egrpc_interceptor`, whose `load/1`
  validates and initializes the list (used by `egrpc_stub`).
- `derive/2` raises `error({removed_option, Key})` for the removed options, as `open/3` does.
- The README describes channels, interceptors, credentials, timeouts and codecs.

Not done, on purpose or left for later:

- The layer 4 of the tests (etcd). `etcdgun` has to be migrated to the new API (section 7).
- The candidates of 4.6 and the `user-agent` header.
- Releasing 0.2.0 and the version of `src/egrpc.app.src` (the maintainer).
- The race between `gun` forwarding a frame and `cancel` is closed by the synchronous call in
  `cancel_and_flush`; streaming calls are not cleaned up at all (egrpc does not observe their end).

## 6. Risks

| Risk | Mitigation |
|---|---|
| A large single change | The phase 0 tests are the safety net for the parts which do not change; do phase 1 in the order given above |
| Derived channels share the connection, `close` is easy to misuse | `close/1,2` raises `not_closable` on derived values, document that the opener keeps the original |
| Hooks now fire for unary calls, so existing interceptors written for streaming only would see unary calls | The old behaviour is replaced anyway; call it out in the release notes and the migration note |
| Per-call chain building was replaced by building at `open/3` and `derive/2` | The chain only depends on the interceptor list, the state is looked up at runtime |
| etcdgun must migrate at the same time | Release notes with an example, see section 7 |

## 7. Impact on etcdgun

This plan does not change etcdgun. This is only a record of what etcdgun can drop once egrpc is done:

| etcdgun today | After egrpc |
|---|---|
| The client's control-plane calls (`MemberList`, `Health`, `Status`, `Authenticate`) go through the user's interceptors, inside the client process | The client keeps bare channels and applies the user's interceptors with `derive/2` only when `pick_channel` hands a channel out |
| The token is put into the channel with `set_info` and read back by the interceptor | `call_credentials`, reading the token the application maintains. `set_info/2` no longer exists |
| `etcdgun_interceptor_auth:refresh_token` calls back `etcdgun_client:refresh_token/1`, which needs the `in_client_process` guard and the `not_a_client` path | The control plane does not go through interceptors, the guard can be removed or kept as a safety net |
| The special handling in `check_connecting/4` which re-authenticates on the channel being checked | Control-plane calls carry the token explicitly, failure handling lives in one place |
| Two auth interceptor modules | One module which only implements the refresh-and-retry in `unary/5` |
| Every `pick_channel` is a `gen_server:call` which also does `set_info` | The token can live in ETS or `persistent_term`, so `pick_channel` does not need the gen_server |
| The user's view of the channel can be closed by the user | Closing a derived channel raises `not_closable` |

Migration note to write: `etcdgun_interceptor_auth` and `etcdgun_stream_interceptor_auth` merged into a
single module on the new behaviour.

## 8. Decisions

### Decided

| Topic | Decision |
|---|---|
| Compatibility | None; this is a breaking change |
| Interceptor option | Only `interceptors`; the two old keys are removed |
| Order | The first element is the outermost |
| Behaviour | New unified behaviour replaces `egrpc_stream_interceptor`, no alias; unified return shape; all phase hooks can return errors |
| Hooks | Fire for all call types; `close_send` and `parse_msg` do not fire for unary; `IsFin` is `fin` in unary |
| Wraps and hooks | Wraps outside, hooks inside the innermost `Next0` |
| `unary/5` | `State` is kept and is the read-only result of `init/1`; `Next` returns only `Result`; `Result` stays `{ok, Resp} \| {error, term()}`, no response headers or trailers |
| `fun/4` | Stays valid in `interceptors` as a stateless shorthand of `unary/5` |
| State | Keyed by position, not by module name |
| Chain | Built once at `open/3` and `derive/2` |
| Derivation | A single `derive/2`; replace semantics; `pipeline_opts()` is `interceptors`, `call_credentials`, `info` |
| Removed | `without_interceptors/1`, `egrpc_stub:set_info/2` |
| Removed options | `open/3` raises `error({removed_option, Key})` for `unary_interceptors` and `stream_interceptors` |
| Invalid input | `derive/2` raises `error(...)` |
| `close` | `error(not_closable)` on a derived channel; `closable` flag in the channel |
| `call_credentials` | A fun which takes only the stream (no call `Opts`), called in `init_req0`, call-level `metadata` takes precedence; exceptions are not caught; the shape of the return value is checked |
| Codec | `codec` option of `open/3` only, default `egrpc_proto`; required `content_type/0` callback |
| `egrpc_json` | Broken today (the encoder returns a map, not text); fixed in this change, together with the codec work |
| `grpc-encoding` | Not changed |
| `ctx` | Postponed |
| "Call end" hook | Not done, the streaming receive path is not redesigned |
| `timeout` | Per-wait semantics unchanged, default 5000 ms, call-level only (no channel default), no `grpc-timeout` header, unary only |
| Stream cleanup on failure | `cancel` + a synchronous call to the connection + `flush` on timeout, transport errors and local errors; nothing on status errors. Verified by running, the decided "flush only on local errors" was not enough (see 4.5) |
| `await_up` | New `await_up/2` with a `Timeout`; `await_up/1` is `await_up(Channel, 5000)` |
| Release | One breaking release in the 0.2.x series |
| Tests | Four layers: eunit; an in-process fake server on cowboy; GripMock (`bavix/gripmock`); optional etcd. The suite does not depend on one particular server, and each external requirement is skipped on its own when missing |
| Small problems | Fixed in separate commits (versions, elp configuration); `headers` is removed with the record split; a `user-agent` header is a later candidate |

### Open

None at the moment.

## 9. Suggested starting point

Phase 0 first, as the safety net. Then phase 1 in the order given in section 5.
