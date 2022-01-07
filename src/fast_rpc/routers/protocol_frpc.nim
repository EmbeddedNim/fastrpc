import tables, macros, strutils
import mcu_utils/msgbuffer
import ../inet_types

export tables
export inet_types
export msgbuffer

## Code copied from: status-im/nim-json-rpc is licensed under the Apache License 2.0
const
  EXT_TAG_EMBEDDED_ARGS = 24 # copy CBOR's "embedded cbor data" tag

type
  FastErrorCodes* = enum
    # Error messages
    FAST_PARSE_ERROR = -27
    INVALID_REQUEST = -26
    METHOD_NOT_FOUND = -25
    INVALID_PARAMS = -24
    INTERNAL_ERROR = -23
    SERVER_ERROR = -22

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
    code*: FastErrorCodes
    msg*: string
    trace*: seq[(string, string, int)]

  FastRpcErrorStackTrace* = object
    code*: int
    msg*: string
    stacktrace*: seq[string]

  # Procedure signature accepted as an RPC call by server
  FastRpcProc* = proc(input: FastRpcParamsBuffer,
                      context: RpcContext
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

  RpcContext* = ref object
    id*: FastRpcId
    sender*: SocketClientSender

  RpcPublishContext* = ref object
    id*: FastRpcId
    sender*: SocketClientSender

  RpcSystemContext* = ref object
    id*: FastRpcId
    sender*: SocketClientSender
    router*: FastRpcRouter

  BinString* = distinct string

proc newFastRpcRouter*(): FastRpcRouter =
  new(result)
  result.procs = initTable[string, FastRpcProc]()
  # result.sysprocs = initTable[string, FastRpcProc]()
  result.stacktraces = defined(debug)

proc listMethods*(rt: FastRpcRouter): seq[string] =
  ## list the methods in the given router. 
  var names = newSeqOfCap[string](rt.procs.len())
  for name in rt.procs.keys():
    names.add name

proc listSysMethods*(rt: FastRpcRouter): seq[string] =
  ## list the methods in the given router. 
  var names = newSeqOfCap[string](rt.sysprocs.len())
  for name in rt.sysprocs.keys():
    names.add name

# pack/unpack BinString
proc `$`*(val: BinString): string {.borrow.}

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

proc rpcPack*(res: FastRpcParamsBuffer): FastRpcParamsBuffer {.inline.} =
  result = res

template rpcPack*(res: JsonNode): FastRpcParamsBuffer =
  var jpack = res.fromJsonNode()
  var ss = MsgBuffer.init(jpack)
  ss.setPosition(jpack.len())
  (buf: ss)

proc rpcPack*[T](res: T): FastRpcParamsBuffer =
  var ss = MsgBuffer.init()
  ss.pack(res)
  result = (buf: ss)

proc rpcUnpack*[T](obj: var T, ss: FastRpcParamsBuffer, resetStream = true) =
  try:
    if resetStream:
      ss.buf.setPosition(0)
    ss.buf.unpack(obj)
  except AssertionDefect as err:
    raise newException(ObjectConversionDefect, "unable to parse parameters")
