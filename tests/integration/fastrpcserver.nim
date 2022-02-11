import std/monotimes, std/os

import fastrpc/server/server
import fastrpc/server/rpcmethods


# Define RPC Server #
rpcRegisterMethodsProcArgs(
        name=initRpcExampleRouter,
        timerQueue: InetEventQueue[int64]
        ):

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

  proc microspub(): int64 {.rpcEventSubscriber(timerQueue).} =

    var ts: int64 = 0
    if timerQueue.tryRecv(ts):
      # let ts = timerQueue.recv()
      echo "ts: ", 0
    ts

  proc testerror(msg: string): string {.rpc.} =
    echo("test error: ", "what is your favorite color?")
    if msg != "Blue":
      raise newException(ValueError, "wrong answer!")
    result = "correct: " & msg


proc timePublisher*(params: (InetEventQueue[int64], int)) {.thread.} =
  let 
    queue = params[0]
    delayMs = params[1]

  while true:
    var ts = isolate int64(getMonoTime().ticks() div 1000)
    logInfo "timePublisher: ", "ts:", ts, "queue:len:", queue.chan.peek()
    discard queue.trySend(ts)
    os.sleep(delayMs)


when isMainModule:
  let inetAddrs = [
    newInetAddr("0.0.0.0", 5656, Protocol.IPPROTO_UDP),
    newInetAddr("0.0.0.0", 5656, Protocol.IPPROTO_TCP),
  ]

  var timer1q = InetEventQueue[int64].init(10)
  var timerThr: Thread[(InetEventQueue[int64], int)]
  timerThr.createThread(timePublisher, (timer1q , 4_000))

  echo "running fast rpc example"
  var router = newFastRpcRouter()
  initRpcExampleRouter(router, timerQueue=timer1q)
  for rpc in router.procs.keys():
    echo "  rpc: ", rpc

  var frpcServer = newFastRpcServer(router, prefixMsgSize=true, threaded=false)
  startSocketServer(inetAddrs, frpcServer)
