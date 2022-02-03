# FastRPC

FastRPC is a both a library and a RPC protocol specification written in portable Nim code. The RPC protocol uses MessagePack (or CBOR) with goals to be portable, relatively lightweight, and fast as possible. The code can run on Zephyr or FreeRTOS/LwIP while also capable and tested to run on Linux (not other *nixs currently). 

## FastRPC Protocol

The FastRPC protocol is based on a variant of [MessagePack-RPC](https://github.com/msgpack-rpc/msgpack-rpc/blob/master/spec.md) however it has several incompatible changes partially to simplify implementation on microcontrollers. 


### MessagePack-RPC Protocol specification

The protocol consists of `Request` message and the corresponding `Response` message. The server must send a `Response` message in reply to the `Request` message. 

#### Packet Types and Framing

This library supports both UDP and TCP, depending what the library user wants. The client will need to know ahead of time whether the server supports TCP or UDP and their ports.

Currently UDP packets make no guarantees of delivery and is up to the RPC api to handle. It's recommended to have idempotent API's in this scenario.


##### TCP Packets and Framing

When using TCP connections a simple framing scheme is used to delineate messages. Each message must be prefixed by a bye-length in big-endian order. This is copied from [Erlang port protocol](https://www.erlang.org/doc/tutorial/c_port.html) for similar reasons.

Note: The default prefix length is 2-byte for messages up to ~65k in length, however, MCUs generally don't gracefully handle packets larger than transport frame size (e.g. ~1400 bytes on ethernet).

In theory, websocket framing could be used but isn't. 

#### `Request` Message

The request message is a four element array as shown below, packed in MessagePack (CBOR) format.

```nim
  [reqtype, msgid, procName, params]
```

The fields are:

1. `reqtype: int8` request message type (current valid request values are `5,7,9,18`)
2. `msgid: int32` sequence number for client to track (async) responses
3. `procName: string` name of the procedure (method) to call 
4. `params: array[MsgPackNodes]` an array of parameters. Arbitray packed MsgPack (CBOR) data matching the method definition. 

The supported types of requests are:
- `Request = 5`
- `Notify = 7`
- `Subscribe = 9`
- `SubscribeStop  = 11`
- `System = 19`

Note: `params` **must** be an array. Passing maps will return an error. This is to optimize deserialization in static languages. The params in the array match the order of the arguments in a function call which is very fast to parse. Maps would require handling out-of-order fields. 

#### `Response` Message

The request message is a three element array as shown below, packed in MessagePack (CBOR) format.

```nim
  [resptype, msgid, result]
```

The fields are:

1. `resptype: int8` response message type (current valid response values are ``)
2. `msgid: int32` sequence number for client to track (async) responses
3. `result: MsgPackNodes` Arbitray packed MsgPack (CBOR) data


The supported types of responses are:
- `Response = 6`
- `Error = 8`
- `Publish = 10`
- `PublishDone = 12`

Note: the `result` type is used to store errors when the response type is `Error (8)`.

#### Basic Request Lifecycle

The client will send a `Request` packet to the server. When UDP is used the server will respond to the same UDP source IP & Port. TCP clients will first need to initialize the socket. 

The server will process the RPC proc and return a `Response` message, unless it encounters and error where the `Error` response type will be sent. It's up to the client to handle these as desired. A `Response` request should expect response. 

The `SystemRequest` is identical to `Request` except that is supports server specific *system* calls. By default this includes methods like `listall` that return all RPC methods handled by the server. API's like *reboot* should likely be a `SystemRequest`. The server may want to require extra security tokens for this case. 

Subscriptions: *TODO*

#### Protocol Semantics / Other Details

TCP packets and UDP packets are treated slightly differently. TCP streams can be used to send/recv larger data than the underlying framesize but is discouraged. Prefer to use `Publish` responses, which are valid to return from normal `Request`. 


### Example

To call `add(int, int)` on a FastRPC server, you'd generate a `Request` message:

```nim
const Request = 5
var callId = 1
var msg = [Request, callId, "add", [1,2]]
assert msg == [5, 1, "add", [1,2]]
```

This would then be serialized using a MsgPack library (or CBOR in the future):

```nim
var msgbinary = msgpack4nim.pack(msg)
assert msgbinary == "\148\5\1\163add\146\1\2"
assert msgbinary == "\x94\x05\x01\xA3add\x92\x01\x02" # hex format
```

When using TCP transport you'd need to prefix the message length:
```nim
var tcpMsgBinary = msgbinary.len().toBeInt16() & msgbinary
assert msgbinary == "\0\10" & "\148\5\1\163add\146\1\2"
assert msgbinary == "\0\10\148\5\1\163add\146\1\2"
```

The response message would be:
```nim
var tcpResponseMsg = "\0\4\147\6\1\3"
var responseMsg = rcpResponseMsg[2..^1] # slice off prefix
assert responseMsg == "\147\6\1\3"

var response = msgpack4nim.unpack(responseMsg)

assert response == [6, 1, 3]
assert response == [Response, 1, 3]

let answer = 3
assert answer == response[2]
```
