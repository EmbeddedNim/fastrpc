
import std/tables, std/sets, std/macros, std/sysrand

import std/selectors

import threading/channels
export sets, selectors, channels

include mcu_utils/threads
import mcu_utils/logging
import mcu_utils/inettypes
import mcu_utils/inetqueues

import msgpack4nim
import msgpack4nim/msgpack2json

export logging, msgpack4nim, msgpack2json

import protocol
export protocol


type
  FastRpcErrorStackTrace* = object
    code*: int
    msg*: string
    stacktrace*: seq[string]

  # Context for servicing an RPC call 
  RpcContext* = object
    id*: FastrpcId
    clientId*: InetClientHandle

  # Procedure signature accepted as an RPC call by server
  FastRpcProc* = proc(params: FastRpcParamsBuffer,
                      context: RpcContext
                      ): FastRpcParamsBuffer {.gcsafe, nimcall.}

  FastRpcRegisterCalls* = proc(router: var FastRpcRouter)

  FastRpcBindError* = object of ValueError
  FastRpcAddressUnresolvableError* = object of ValueError

  RpcSubId* = int64
  RpcSubIdQueue* = InetEventQueue[InetQueueItem[(RpcSubId, SelectEvent)]]

  FastRpcEventProc* = proc(): FastRpcParamsBuffer {.gcsafe, closure.}

  RpcSubClients* = object
    eventProc*: FastRpcEventProc
    subs*: TableRef[InetClientHandle, RpcSubId]

  FastRpcRouter* = ref object
    procs*: Table[string, FastRpcProc]
    sysprocs*: Table[string, FastRpcProc]
    subEventProcs*: Table[SelectEvent, RpcSubClients]
    subNames*: Table[string, SelectEvent]
    stacktraces*: bool
    inQueue*: InetMsgQueue
    outQueue*: InetMsgQueue
    registerQueue*: RpcSubIdQueue

proc randBinString*(): RpcSubId =
  var idarr: array[sizeof(RpcSubId), byte]
  if urandom(idarr):
    result = cast[RpcSubId](idarr)
  else:
    result = RpcSubId(0)

proc newFastRpcRouter*(): FastRpcRouter =
  new(result)
  result.procs = initTable[string, FastRpcProc]()
  result.sysprocs = initTable[string, FastRpcProc]()
  result.subEventProcs = initTable[SelectEvent, RpcSubClients]()
  result.stacktraces = defined(debug)

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

proc rpcPack*(res: FastRpcParamsBuffer): FastRpcParamsBuffer {.inline.} =
  result = res

template rpcPack*(res: JsonNode): FastRpcParamsBuffer =
  var jpack = res.fromJsonNode()
  var ss = MsgBuffer.init(jpack)
  ss.setPosition(jpack.len())
  FastRpcParamsBuffer(buf: ss)

proc rpcPack*[T](res: T): FastRpcParamsBuffer =
  var ss = MsgBuffer.init()
  ss.pack(res)
  result = FastRpcParamsBuffer(buf: ss)

proc rpcUnpack*[T](obj: var T, ss: FastRpcParamsBuffer, resetStream = true) =
  try:
    if resetStream:
      ss.buf.setPosition(0)
    ss.buf.unpack(obj)
  except AssertionDefect as err:
    raise newException(ObjectConversionDefect, "unable to parse parameters: " & err.msg)
