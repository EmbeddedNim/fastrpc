import tables, macros, strutils
import std/sysrand
import std/hashes

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
    frRequest       = 5
    frResponse      = 6
    frNotify        = 7
    frError         = 8
    frSubscribe     = 9
    frPublish       = 10
    frSubscribeStop = 11
    frPublishDone   = 12
    frSystemRequest = 19
    frUnsupported   = 23
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
  FastRpcProc* = proc(params: FastRpcParamsBuffer, context: RpcContext): FastRpcParamsBuffer {.gcsafe, nimcall.}

  FastRpcBindError* = object of ValueError
  FastRpcAddressUnresolvableError* = object of ValueError

  FastRpcRouter* = ref object
    procs*: Table[string, FastRpcProc]
    sysprocs*: Table[string, FastRpcProc]
    stacktraces*: bool
    when compileOption("threads"):
      threads*: TableRef[BinString, Thread[FastRpcThreadArg]]

  RpcContext* = ref object
    id*: FastRpcId
    sender*: SocketClientSender
    router*: FastRpcRouter

  BinString* = int

  FastRpcThreadArg* = (FastRpcProc, FastRpcParamsBuffer, RpcContext)

# proc `$`*(val: BinString): string {.borrow.}
# proc `hash`*(x: BinString): Hash {.borrow.}
# proc `==`*(x, y: BinString): bool {.borrow.}

proc randBinString*(): BinString =
  var idarr: array[sizeof(int), byte]
  result =
    if urandom(idarr):
      BinString(cast[int](idarr))
    else:
      BinString(0)

proc newFastRpcRouter*(): FastRpcRouter =
  new(result)
  result.procs = initTable[string, FastRpcProc]()
  # result.sysprocs = initTable[string, FastRpcProc]()
  result.stacktraces = defined(debug)
  when compiles(typeof Thread):
    result.threads = newTable[BinString, Thread[FastRpcThreadArg]]()

proc listMethods*(rt: FastRpcRouter): seq[string] =
  ## list the methods in the given router. 
  result = newSeqOfCap[string](rt.procs.len())
  for name in rt.procs.keys():
    result.add name

proc listSysMethods*(rt: FastRpcRouter): seq[string] =
  ## list the methods in the given router. 
  result = newSeqOfCap[string](rt.sysprocs.len())
  for name in rt.sysprocs.keys():
    result.add name

# pack/unpack MsgBuffer
proc pack_type*[ByteStream](s: ByteStream, x: FastRpcParamsBuffer) =
  s.write(x.buf.data, x.buf.pos)

proc unpack_type*[ByteStream](s: ByteStream, x: var FastRpcParamsBuffer) =
  var params = s.readStrRemaining()
  x.buf = MsgBuffer.init()
  shallowCopy(x.buf.data, params)

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
    raise newException(ObjectConversionDefect, "unable to parse parameters: " & err.msg)
