import std/monotimes, std/os

import mcu_utils/allocstats

import fastrpc/server/fastrpcserver
import fastrpc/server/rpcmethods

import random

# Define RPC Server #

proc addBasicExampleRpcs(router: var FastRpcRouter) =
  type AddRpcParams = object
    a: int
    b: int

  proc add(args: AddRpcParams, context: RpcContext): int =
    result = args.a + args.b

  proc addRpc(params: FastRpcParamsBuffer, context: RpcContext): FastRpcParamsBuffer {.gcsafe, nimcall.} =
    var obj: AddRpcParams
    obj.rpcUnpack(params)

    let res = add(obj, context)
    result = res.rpcPack()
  
  router.rpcRegister("add", addRpc)


# Define RPC Server with helper pragmas #
proc addExampleRpcs(router: var FastRpcRouter) =

  proc addAll(vals: seq[int]): int {.rpcRegister(router).} =
    for val in vals:
      result = result + val

  proc mul(a: int, b: int): int {.rpcRegister(router).} =
    result = a * b

  proc multAll(x: int, vals: seq[int]): seq[int] {.rpcRegister(router).} =
    result = newSeqOfCap[int](vals.len())
    for val in vals:
      result.add val * x

  proc echos(msg: string): string {.rpcRegister(router).} =
    echo("echos: ", "hello ", msg)
    result = "hello: " & msg

  proc echorepeat(msg: string, count: int): string {.rpcRegister(router).} =
    let rmsg = "hello " & msg
    for i in 0..count:
      echo("echos: ", rmsg)
      # discard context.sender(rmsg)
      discard rpcReply(rmsg)
      os.sleep(400)
    result = "k bye"

  proc simulatelongcall(cntMillis: int): Millis {.rpcRegister(router).} =

    let t0 = getMonoTime().ticks div 1_000_000
    echo("simulatelongcall: ", )
    os.sleep(cntMillis)
    let t1 = getMonoTime().ticks div 1_000_000

    return Millis(t1-t0)

  proc testerror(msg: string): string {.rpcRegister(router).} =
    echo("test error: ", "what is your favorite color?")
    if msg != "Blue":
      raise newException(ValueError, "wrong answer!")
    result = "correct: " & msg

when isMainModule:
  let inetAddrs = [
    newInetAddr("0.0.0.0", 5656, Protocol.IPPROTO_UDP),
    newInetAddr("0.0.0.0", 5656, Protocol.IPPROTO_TCP),
    newInetAddr("::", 5555, Protocol.IPPROTO_UDP),
    newInetAddr("::", 5555, Protocol.IPPROTO_TCP),
  ]

  echo "running fast rpc example"
  var router = newFastRpcRouter()

  # register the `exampleRpcs` with our RPC router
  router.addBasicExampleRpcs()
  router.addExampleRpcs()

  # print out all our new rpc's!
  for rpc in router.procs.keys():
    echo "  rpc: ", rpc

  var frpcServer = newFastRpcServer(router, prefixMsgSize=true, threaded=false)
  startSocketServer(inetAddrs, frpcServer)
