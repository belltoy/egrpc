# egrpc

A gRPC client library for Erlang/OTP built on top of [gun](https://github.com/ninenines/gun).

## Usage

```erlang
Host = "127.0.0.1",
Port = 50052,
Opts = #{},
{ok, Channel0} = egrpc_stub:open(Host, Port, Opts),
{ok, Channel1} = egrpc_stub:await_up(Channel0),

% Call via generated client API method
Args = #{},
Result = my_grpc_api:method(Channel1, Args),

% Close channel
egrpc_stub:close(Channel1).
```

## License

This project is released under the [Apache License 2.0](LICENSE.md).
