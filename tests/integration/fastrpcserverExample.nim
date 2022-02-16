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
  TimerDataQ = InetEventQueue[seq[int64]]

  TimerOptions {.rpcOption.} = object
    delay: Millis
    count: int

DefineRpcTaskOptions[TimerOptions](name=timerOptionsRpcs):
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
    result = option.delay.int
  

proc timeSerializer(queue: TimerDataQ): Table[string, seq[int64]] {.rpcSerializer.} =
  ## called by the socket server every time there's data
  ## on the queue argument given the `rpcEventSubscriber`.
  ## 
  var tvals: seq[int64]
  if queue.tryRecv(tvals):
    echo "ts: ", tvals
  {"ts": tvals}.toTable()

proc timeSampler*(queue: TimerDataQ, opts: TaskOption[TimerOptions]) {.rpcThread.} =
  ## Thread example that runs the as a time publisher. This is a reducer
  ## that gathers time samples and outputs arrays of timestamp samples.
  var data = opts.data

  while true:
    var tvals = newSeqOfCap[int64](data.count)
    for i in 0..<data.count:
      var ts = int64(getMonoTime().ticks() div 1000)
      tvals.add ts
      os.sleep(data.delay.int div (2*data.count))

    logInfo "timePublisher: ", "ts:", tvals.repr
    logInfo "queue:len:", queue.chan.peek()
    var qvals = isolate tvals

    # let newOpts = opts.getUpdatedOption()
    # if newOpts.isSome:
      # echo "setting new parameters: ", repr(newOpts)
      # data = newOpts.get()

    discard queue.trySend(qvals)
    os.sleep(data.delay.int)

proc streamThread*(arg: ThreadArg[seq[int64], TimerOptions]) {.thread, nimcall.} = 
  echo "streamThread: ", repr(arg.opt.data)
  timeSampler(arg.queue, arg.opt)


when isMainModule:
  let inetAddrs = [
    newInetAddr("0.0.0.0", 5656, Protocol.IPPROTO_UDP),
    newInetAddr("0.0.0.0", 5656, Protocol.IPPROTO_TCP),
  ]

  echo "setup timer thread"
  var
    timer1q = TimerDataQ.init(10)
    timerOpt = TimerOptions(delay: 100.Millis, count: 10)

  var tchan: Chan[TimerOptions] = newChan[TimerOptions](1)
  var topt = TaskOption[TimerOptions](data: timerOpt, ch: tchan)
  var arg = ThreadArg[seq[int64],TimerOptions](queue: timer1q, opt: topt)
  var result: RpcStreamThread[seq[int64], TimerOptions]
  createThread[ThreadArg[seq[int64], TimerOptions]](result, streamThread, move arg)

  # echo "start timer thread"
  # var timerThr = startDataStream(
  #   timeSampler,
  #   streamThread,
  #   timer1q,
  #   timerOpt,
  # )

  os.sleep(5_000)
  echo "running fast rpc example"
  var router = newFastRpcRouter()

  # register the `exampleRpcs` with our RPC router
  router.registerRpcs(exampleRpcs)

  # register a `datastream` with our RPC router
  echo "register datastream"
  router.registerDataStream(
    "microspub",
    serializer=timeSerializer,
    reducer=timeSampler, 
    queue = timer1q,
    option = TimerOptions(delay: 100.Millis),
    optionRpcs = timerOptionsRpcs,
  )

  # print out all our new rpc's!
  for rpc in router.procs.keys():
    echo "  rpc: ", rpc

  var frpcServer = newFastRpcServer(router, prefixMsgSize=true, threaded=false)
  startSocketServer(inetAddrs, frpcServer)
