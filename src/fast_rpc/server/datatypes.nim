
import std/tables, std/macros, std/sysrand
import std/isolation
import std/selectors

import threading/channels
export selectors, channels

include mcu_utils/threads
import mcu_utils/logging

import msgpack4nim
import msgpack4nim/msgpack2json

export logging, msgpack4nim, msgpack2json

import protocol
export protocol

type
  # QMsgBuffer* = object
  #   buffer: ptr UncheckedArray[byte]
  #   pos*: int

  QMsgBuffer* = UniquePtr[MsgBuffer]


type
  FastRpcErrorStackTrace* = object
    code*: int
    msg*: string
    stacktrace*: seq[string]

  # Context for servicing an RPC call 
  RpcContext* = object
    id*: FastrpcId
    clientId*: InetClientHandle

  RpcQueueItem* = ref object
    cid*: InetClientHandle
    data*: QMsgBuffer

  RpcQueue* = ref object
    evt*: SelectEvent # eventfds
    chan*: Chan[RpcQueueItem]

  # Procedure signature accepted as an RPC call by server
  FastRpcProc* = proc(params: FastRpcParamsBuffer,
                      context: RpcContext
                      ): FastRpcParamsBuffer {.gcsafe, nimcall.}

  FastRpcBindError* = object of ValueError
  FastRpcAddressUnresolvableError* = object of ValueError

  RpcSubId* = int64

  FastRpcRouter* = ref object
    procs*: Table[string, FastRpcProc]
    sysprocs*: Table[string, FastRpcProc]
    stacktraces*: bool
    inQueue*: RpcQueue
    outQueue*: RpcQueue

proc newRpcQueueItem*(cid: InetClientHandle, data: sink QMsgBuffer): RpcQueueItem =
  new(result)
  result.cid = cid
  result.data = move data

proc newRpcQueue*(size: int): RpcQueue =
  new(result)
  result.evt = newSelectEvent()
  result.chan = newChan[RpcQueueItem](size)

proc send*(rq: RpcQueue, cid: InetClientHandle, data: sink QMsgBuffer) =
  logDebug("datatypes:send:")
  var item = isolate RpcQueueItem( cid: cid, data: data)
  logDebug("datatypes:send:item: ", repr item)
  rq.chan.send(item)
  rq.evt.trigger()

proc trySend*(rq: RpcQueue, cid: InetClientHandle, data: sink QMsgBuffer): bool =
  logDebug("datatypes:send:")
  var item = isolate newRpcQueueItem(cid, data)
  let res = channels.trySend(
    rq.chan,
    item
  )
  if res:
    logDebug("datatypes:send:trigger: ", repr(rq.evt))
    rq.evt.trigger()
  return res

proc recv*(rq: RpcQueue): RpcQueueItem =
  logDebug("datatypes:recv:")
  rq.chan.recv(result)


proc randBinString*(): RpcSubId =
  var idarr: array[sizeof(RpcSubId), byte]
  if urandom(idarr):
    result = cast[RpcSubId](idarr)
  else:
    result = RpcSubId(0)

proc newFastRpcRouter*(): FastRpcRouter =
  new(result)
  result.procs = initTable[string, FastRpcProc]()
  # result.sysprocs = initTable[string, FastRpcProc]()
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
  (buf: ss)

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
