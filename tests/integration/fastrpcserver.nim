import std/monotimes, std/os

import fast_rpc/server/server
import fast_rpc/server/rpcmethods


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

  proc simulatelongcall(cntMillis: int): Millis {.rpc.} =

    let t0 = getMonoTime().ticks div 1_000_000
    echo("simulatelongcall: ", )
    os.sleep(cntMillis)
    let t1 = getMonoTime().ticks div 1_000_000

    return Millis(t1-t0)

  # proc microspub(count: int): int {.rpcPublisherThread().} =
  #   # var subid = subs.subscribeWithThread(context, run_micros, % delay)
  #   while true:
  #     var ts = int(getMonoTime().ticks() div 1000)
  #     discard rpcPublish(ts)
  #     os.sleep(count)

  # proc adcstream(count: int): seq[int] {.rpcPublisherThread().} =
  #   # var subid = subs.subscribeWithThread(context, run_micros, % delay)
  #   while true:
  #     echo "adcstream ts'es"
  #     var vals = newSeq[int]()
  #     for i in 0..<20:
  #       var ts = int(getMonoTime().ticks() div 1000)
  #       vals.add ts
  #     echo "adcstream publish"
  #     discard rpcPublish(vals)
  #     os.sleep(count)

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

  var frpcServer = newFastRpcServer(router, prefixMsgSize=true, threaded=false)
  startSocketServer(inetAddrs, frpcServer)
