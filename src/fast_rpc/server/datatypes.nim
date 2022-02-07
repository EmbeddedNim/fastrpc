
import std/tables, std/macros, std/sysrand
import threading/channels
export channels

include mcu_utils/threads
import mcu_utils/logging

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
  RpcQueue* = ref object
    event*: InetClientHandle # eventfds
    queue*: Chan[FastRpcParamsBuffer]

  RpcContext* = ref object
    callId*: FastRpcId
    clientId*: InetClientHandle
    queue*: RpcQueue

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

# proc `$`*(val: BinString): string {.borrow.}
# proc `hash`*(x: BinString): Hash {.borrow.}
# proc `==`*(x, y: BinString): bool {.borrow.}
proc send(ctx: RpcQueue, data: FastRpcParamsBuffer) =


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
  result = (buf: ss)

proc rpcUnpack*[T](obj: var T, ss: FastRpcParamsBuffer, resetStream = true) =
  try:
    if resetStream:
      ss.buf.setPosition(0)
    ss.buf.unpack(obj)
  except AssertionDefect as err:
    raise newException(ObjectConversionDefect, "unable to parse parameters: " & err.msg)
