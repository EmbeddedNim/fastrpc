import std/monotimes, std/os

import fast_rpc/socketserver
import fast_rpc/routers/router_fastrpc
import fast_rpc/socketserver/fast_rpc_impl

const
  VERSION = "1.0.0"

# Define RPC Server #
rpc_methods(rpcExample):

  proc add(a: int, b: int): int {.rpc, system.} =
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
    result = "done"

  proc testerror(msg: string): string {.rpc.} =
    echo("test error: ", "what is your favorite color?")
    if msg != "Blue":
      raise newException(ValueError, "wrong answer!")
    result = "correct: " & msg

  # proc tickmicros(delayms: int, context: RpcContext): string {.rpc, subscription, thread.} =
  #   os.sleep(delayms)
  #   var value: JsonNode = %* {"subscription": context.subId, "result": ts}
  #   var msg: string = value.rpcPack()

  #   let res = sender(msg)
  #   if not res: break
  #   os.sleep(delay)

when isMainModule:
  let inetAddrs = [
    newInetAddr("0.0.0.0", 5656, Protocol.IPPROTO_UDP),
    newInetAddr("0.0.0.0", 5656, Protocol.IPPROTO_TCP),
  ]

  echo "main: ROUTER: "
  var router = rpcExample()
  # var router = newFastRpcRouter()
  # rpcExample(router)
  for rpc in router.procs.keys():
    echo "  rpc: ", rpc
  startSocketServer(inetAddrs, newFastRpcServer(router, prefixMsgSize=true))
  # var rpc = rpc_server()
  # echo "rpc: ", repr rpc
