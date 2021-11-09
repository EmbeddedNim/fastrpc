import tables, strutils, macros, options
import ../binutils

## Code copied from: status-im/nim-json-rpc is licensed under the Apache License 2.0
const
  EMBEDDED_ARGS_TAG* = 24 # copy CBOR's "embedded cbor data" tag

type
  RpcType* {.size: sizeof(uint8).} = enum
    rtpCast        = 1
    rtpCall        = 2
    rtpResponse    = 3
    rtpError       = 4
    rtpPublish     = 5
    rtpSubscribe   = 6
    rtpUnsubscribe = 7
    rtpMax = 23 # numbers less than this store in single mpack/cbor byte

  RpcId* = distinct uint16
  RpcPartId* = distinct uint16
  RpcParamsBuffer* = tuple[buf: MsgBuffer]

  FastRpcCall* = object
    rpcType*: RpcType
    rpcMsgId*: RpcId
    rpcMsgPartId*: RpcPartId
    procName*: string
    params*: RpcParamsBuffer # - we handle params below

  FastRpcResponse* = object
    rpcType*: RpcType
    rpcMsgId*: RpcId
    rpcMsgPartId*: RpcPartId
    params*: RpcParamsBuffer # - we handle params below

  FastRpcErrorParams* = object
    code: int32
    msg: string
    stacktrace: seq[string]

  FastRpcError* {.size: sizeof(uint8).} = enum
    rjeInvalidPacking,
    rjeVersionError,
    rjeNoMethod,
    rjeNoId,
    rjeNoParams

  RpcErrorContainer* = tuple[err: FastRpcError, msg: string]

  # Procedure signature accepted as an RPC call by server
  FastRpcProc* = proc(input: MsgBuffer): MsgBuffer {.gcsafe.}

  RpcBindError* = object of ValueError
  RpcAddressUnresolvableError* = object of ValueError

  RpcRouter* = ref object
    procs*: Table[string, FastRpcProc]
    buffer*: int

# pack/unpack MsgBuffer
proc pack_type*[ByteStream](s: ByteStream, x: RpcParamsBuffer) =
  s.pack_ext(body.len, EMBEDDED_ARGS_TAG)
  s.write(x.data, x.pos)

# help the compiler to decide
proc unpack_type*[ByteStream](s: ByteStream, x: var RpcParamsBuffer) =
  let (extype, extlen) = s.unpack_ext()
  var extbody = s.readStr(extlen)
  shallowCopy(x.data, s)

proc wrapResponse*(rpcCall: FastRpcCall, ret: MsgBuffer): FastRpcResponse = 
  result.rpcType = rtpResponse

proc wrapError*(rpcCall: FastRpcCall, code: int, message: string): FastRpcResponse = 
  result.rpcType = rtpError
  result.rpcMsgId = rpcCall.rpcMsgId
  var ss = MsgBuffer.init()
  ss.pack()

proc rpcParseError*(): FastRpcError = 
  result.rpcType = rtpError
  result.rpcMsgId = 0
    "error": { "code": -32700, "message": "Parse error" },
  result.params = 

proc rpcInvalidRequest*(detail: string): JsonNode = 
  result = %* {
    "jsonrpc": "2.0",
    "error": { "code": -32600, "message": "Invalid request", "detail": detail },
    "id": nil
  }

proc rpcInvalidRequest*(id: int, detail: string): JsonNode = 
  result = %* {
    "jsonrpc": "2.0",
    "error": { "code": -32600, "message": "Invalid request", "detail": detail },
    "id": id
  }
