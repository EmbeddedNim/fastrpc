import std/monotimes, std/os

import fastrpc/server/fastrpcserver
import fastrpc/server/rpcmethods

import json

# Define RPC Server #
DefineRpcs(name=exampleRpcs):

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


  proc testerror(msg: string): string {.rpc.} =
    echo("test error: ", "what is your favorite color?")
    if msg != "Blue":
      raise newException(ValueError, "wrong answer!")
    result = "correct: " & msg

type
  TimerDataQueue = InetEventQueue[seq[int64]]
  TimerOptions = object
    delay: Millis

DefineRpcOptions[TimerOptions](name=timerOptionsRpcs):

  proc setDelay(opt: var TimerOptions, delayMs: int): bool {.rpcSetter.} =
    ## called by the socket server every time there's data
    ## on the queue argument given the `rpcEventSubscriber`.
    ## 
    if delayMs < 10_000:
      opt.delay = Millis(delayMs)
      return true
    else:
      return false
  
  proc getDelay(option: var TimerOptions): int {.rpcGetter.} =
    ## called by the socket server every time there's data
    ## on the queue argument given the `rpcEventSubscriber`.
    ## 
    result = option.delayMs
  

proc timeSerializer(queue: TimerDataQueue): Table[string, seq[int64]] {.rpcSerializer.} =
  ## called by the socket server every time there's data
  ## on the queue argument given the `rpcEventSubscriber`.
  ## 
  var tvals: seq[int64]
  if queue.tryRecv(tvals):
    echo "ts: ", tvals
  {"ts": tvals}.toTable()

var adcDriver: AdcDriverObj

proc timeSamplerReducer*(params: (TimerDataQueue [seq[int64]], TimerOptions)) {.thread.} =
  ## Thread example that runs the as a time publisher. This is a reducer
  ## that gathers time samples and outputs arrays of timestamp samples.
  let 
    queue = params[0]
    option = params[1]
    n = 10

  adcDriver.setupISR()


  while true:
    var tvals = newSeqOfCap[int64](n)
    for i in 0..n:
      var ts = int64(getMonoTime().ticks() div 1000)
      tvals.add ts
      os.sleep(delayMs div (2*n))

    logInfo "timePublisher: ", "ts:", tvals[^1], "queue:len:", queue.chan.peek()
    var qvals = isolate tvals
    if option.isUpdated:
      adc1.resetCSPeed()

    discard queue.trySend(qvals)
    os.sleep(delayMs)


when isMainModule:
  let inetAddrs = [
    newInetAddr("0.0.0.0", 5656, Protocol.IPPROTO_UDP),
    newInetAddr("0.0.0.0", 5656, Protocol.IPPROTO_TCP),
  ]

  var timer1q = InetEventQueue[seq[int64]].init(10)
  var timerThr: Thread[(InetEventQueue[seq[int64]], int)]
  timerThr.createThread(timeSamplerReducer, (timer1q , 1_000))

  echo "running fast rpc example"
  var router = newFastRpcRouter()
  router.registerRpcs(exampleRpcs)
  router.registerRpcs(exampleRpcSubscription,
                           timerQueue=timer1q)
  router.registerDatastream("ADC1",
                            serializer=ADC1serializer,
                            reducer=ADC1reducer, 
                            queue = timer1q,
                            option = TimerOptions(delay: 100.Millis),
                            optionRpcs = timerOptionsRpcs,
                            )
  for rpc in router.procs.keys():
    echo "  rpc: ", rpc

  var frpcServer = newFastRpcServer(router, prefixMsgSize=true, threaded=false)
  startSocketServer(inetAddrs, frpcServer)
