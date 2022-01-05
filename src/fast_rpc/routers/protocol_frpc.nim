import tables, macros, strutils
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
    frRequest     = 5
    frResponse    = 6
    frNotify      = 7 # Unsupported
    frError       = 8
    frSubscribe   = 9
    frPublish     = 10
    frSystemRequest = 11
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
    trace*: seq[StackTraceEntry]

  FastRpcErrorStackTrace* = object
    code*: int
    msg*: string
    stacktrace*: seq[string]

  # Procedure signature accepted as an RPC call by server
  FastRpcProc* = proc(input: FastRpcParamsBuffer,
                      context: SocketClientSender
                      ): FastRpcParamsBuffer {.gcsafe, nimcall.}
  FastRpcSysProc* = proc(input: FastRpcParamsBuffer,
                         context: RpcSystemContext,
                         ): FastRpcParamsBuffer {.gcsafe, nimcall.}

  FastRpcBindError* = object of ValueError
  FastRpcAddressUnresolvableError* = object of ValueError

  FastRpcRouter* = ref object
    procs*: Table[string, FastRpcProc]
    sysprocs*: Table[string, FastRpcSysProc]
    stacktraces*: bool

  FastRpcSubsArgs* = ref object
    subid*: BinString
    data*: JsonNode
    sender*: SocketClientSender 

  RpcSystemContext* = ref object
    sender*: SocketClientSender

  BinString* = distinct string

proc newFastRpcRouter*(): FastRpcRouter =
  new(result)
  result.procs = initTable[string, FastRpcProc]()
  # result.sysprocs = initTable[string, FastRpcProc]()
  result.stacktraces = defined(debug)

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

proc pack_type*[ByteStream](s: ByteStream, x: StackTraceEntry) =
  echo "packing ste: ", repr x
  s.pack_array(3)
  s.pack($x.procname)
  s.pack(rsplit($(x.filename), '/', maxsplit=1)[^1])
  s.pack(x.line)

proc unpack_type*[ByteStream](s: ByteStream, x: var StackTraceEntry) =
  assert s.unpack_array() == 3
  s.unpack(x.procname)
  s.unpack(x.filename)
  s.unpack(x.line)
