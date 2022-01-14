import std/monotimes, std/os

import fast_rpc/socketserver
import fast_rpc/routers/router_fastrpc
import fast_rpc/socketserver/fast_rpc_impl

const
  VERSION = "1.0.0"


# Define RPC Server #
rpcRegisterMethodsProc(name=initRpcExampleRouter):

  proc add(a: int, b: int): int {.rpc.} =
    result = 1 + a + b

  proc addAll(vals: seq[int]): int {.rpc.} =
    for val in vals:
      result = result + val

  proc multAll(x: int, vals: seq[int]): seq[int] {.rpc.} =
    result = newSeqOfCap[int](vals.len())
    for val in vals:
      result.add val * x

  proc echos(msg: string): string {.rpc.} =
    echo("echos: ", "hello ", msg)
    result = "hello: " & msg

  proc echorepeat(msg: string, count: int): string {.rpc.} =
    let rmsg = "hello " & msg
    for i in 0..count:
      echo("echos: ", rmsg)
      # discard context.sender(rmsg)
      discard rpcReply(rmsg)
      os.sleep(400)
    result = "k bye"

  proc microspub(count: int): int {.rpcPublisherThread().} =
    # var subid = subs.subscribeWithThread(context, run_micros, % delay)
    while true:
      var ts = int(getMonoTime().ticks() div 1000)
      discard rpcPublish(ts)
      os.sleep(count)

  proc testerror(msg: string): string {.rpc.} =
    echo("test error: ", "what is your favorite color?")
    if msg != "Blue":
      raise newException(ValueError, "wrong answer!")
    result = "correct: " & msg

when isMainModule:
  let inetAddrs = [
    newInetAddr("0.0.0.0", 5656, Protocol.IPPROTO_UDP),
    newInetAddr("0.0.0.0", 5656, Protocol.IPPROTO_TCP),
  ]

  echo "running fast rpc example"
  var router = initRpcExampleRouter()
  for rpc in router.procs.keys():
    echo "  rpc: ", rpc
  startSocketServer(inetAddrs, newFastRpcServer(router, prefixMsgSize=true))
