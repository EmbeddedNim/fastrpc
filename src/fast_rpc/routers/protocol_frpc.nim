import tables, macros
import mcu_utils/msgbuffer
import ../inet_types

export tables
export inet_types
export msgbuffer

## Code copied from: status-im/nim-json-rpc is licensed under the Apache License 2.0
const
  EXT_TAG_EMBEDDED_ARGS* = 24 # copy CBOR's "embedded cbor data" tag

  # Error messages
  FAST_PARSE_ERROR* = -27
  INVALID_REQUEST* = -26
  METHOD_NOT_FOUND* = -25
  INVALID_PARAMS* = -24
  INTERNAL_ERROR* = -23
  SERVER_ERROR* = -22

type
  FastRpcType* {.size: sizeof(uint8).} = enum
    # Fast RPC Types
    frRequest     = 0
    frResponse    = 1
    frNotify      = 2 # Unsupported
    frError       = 3
    frSubscribe   = 4
    frPublish     = 5
    frUnsupported = 23
    # rtpMax = 23 # numbers less than this store in single mpack/cbor byte

  FastRpcParamsBuffer* = tuple[buf: MsgBuffer]
  FastRpcId* = int

  FastRpcRequest* = object
    kind*: FastRpcType
    id*: FastRpcId
    procName*: string
    params*: FastRpcParamsBuffer # - we handle params below

  FastRpcResponse* = object
    kind*: FastRpcType
    id*: int
    result*: FastRpcParamsBuffer # - we handle params below

  FastRpcError* = ref object
    code*: int
    msg*: string

  FastRpcErrorStackTrace* = object
    code*: int
    msg*: string
    stacktrace*: seq[string]

  # Procedure signature accepted as an RPC call by server
  FastRpcProc* = proc(input: FastRpcParamsBuffer, context: SocketClientSender): FastRpcParamsBuffer {.gcsafe, nimcall.}

  FastRpcBindError* = object of ValueError
  FastRpcAddressUnresolvableError* = object of ValueError

  FastRpcRouter* = ref object
    procs*: Table[string, FastRpcProc]

  FastRpcSubsArgs* = ref object
    subid*: BinString
    data*: JsonNode
    sender*: SocketClientSender 

  BinString* = distinct string

# pack/unpack BinString
proc pack_type*[ByteStream](s: ByteStream, val: BinString) =
  s.pack_bin(len(val.string))
  s.write(val.string)

proc unpack_type*[ByteStream](s: ByteStream, val: var BinString) =
  let bstr = s.unpack_bin()
  val = BinString(s.readStr(bstr))

# pack/unpack MsgBuffer
proc pack_type*[ByteStream](s: ByteStream, x: FastRpcParamsBuffer) =
  s.pack_ext(x.buf.data.len(), EXT_TAG_EMBEDDED_ARGS)
  s.write(x.buf.data, x.buf.pos)

proc unpack_type*[ByteStream](s: ByteStream, x: var FastRpcParamsBuffer) =
  let (extype, extlen) = s.unpack_ext()
  var extbody = s.readStr(extlen)
  x.buf = MsgBuffer.init()
  shallowCopy(x.buf.data, extbody)
