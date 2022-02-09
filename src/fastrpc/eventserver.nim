import std/selectors
import std/monotimes
import std/random

import mcu_utils/logging

type

  FastProducer* = object

template fastProducer*() {.pragma.}

type
  AdcReading* = object
    timestamp: int64
    sequence: int
    samples: seq[int32]

var chAdcReadings*: Channel[seq[AdcReading]]

proc adcSamples(): seq[int32] =
  return @[
    rand(high(int32)-1).int32,
    rand(high(int32)-1).int32
  ]

proc adcTask*(event: SelectEvent, packetSize, decimateCount: int) {.fastProducer.} =
  var sample_count = 0
  while true:
    echo("adc reading")
    var adcData = newSeq[AdcReading]()
    for i in 0..packetSize:
      # readings
      var samples = adcSamples()
      # skip n readings
      for i in 1..decimateCount: samples = adcSamples()

      var reading = AdcReading(
        timestamp: getMonoTime().ticks() div 1000,
        sequence: sample_count,
        samples: samples
      )
      adcData.add(reading)
      sample_count.inc()

    logInfo("adc:", "publishing")
    if chAdcReadings.trySend(adcData):
      event.trigger()

proc event_notification_test*(): bool =
  var selector = newSelector[int]()
  var event = newSelectEvent()
  selector.registerEvent(event, 1)
  var rc0 = selector.select(0)
  event.trigger()
  var rc1 = selector.select(0)
  event.trigger()
  var rc2 = selector.select(0)
  var rc3 = selector.select(0)
  assert(len(rc0) == 0 and len(rc1) == 1 and len(rc2) == 1 and len(rc3) == 0)
  var ev1 = selector.getData(rc1[0].fd)
  var ev2 = selector.getData(rc2[0].fd)
  assert(ev1 == 1 and ev2 == 1)
  selector.unregister(event)
  event.close()
  assert(selector.isEmpty())
  selector.close()
  result = true

proc threadRunner*(args: FastRpcThreadArg) =
  try:
    os.sleep(1)
    let fn = args[0]
    var val = fn(args[1], args[2])
    discard rpcReply(args[2], val, frPublishDone)
  except InetClientDisconnected:
    logWarn("client disconnected for subscription")
    discard


# ========================= Define RPC Server ========================= #
# template mkSubscriptionMethod(rpcname: untyped, rpcfunc: untyped): untyped = 
#   let subproc =
#     proc (params: FastRpcParamsBuffer, context: RpcContext): FastRpcParamsBuffer {.gcsafe, nimcall.} =
#       echo "rpcPublishThread: ", repr params
#       let subid = randBinString()
#       context.id = subid
#       context.router.threads[subid] = Thread[FastRpcThreadArg]()
#       let args: (FastRpcProc, FastRpcParamsBuffer, RpcContext) = (rpcfunc, params, context)
#       createThread(context.router.threads[subid], threadRunner, args)
#       result = rpcPack(("subscription", subid,))
  
#   subproc
