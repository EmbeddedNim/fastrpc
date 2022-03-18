import std/monotimes, std/os, std/json, std/tables
import std/random, std/json

import mcu_utils/[logging]
import nephyr/[times, nets]

import fastrpc/server/fastrpcserver
import fastrpc/server/rpcmethods

# * Sensor identity (name, location, etc)
# * Firmware version
# * FastRPC server port
# * MAC address
# * Link Local address

type
  DiscoveryData* = object
    uptime*: int64
    identifier*: string
    fwversion*: array[3, int]
    servicePort*: int
    linkLocal*: array[16, uint8]

  DiscoveryOptions* {.rpcOption.} = object
    delay*: Millis
    servicePort*: Port

var discovery: DiscoveryData

DefineRpcTaskOptions[DiscoveryOptions](name=discoveryOptionsRpcs):
  discard

proc discoverySerializer*(
    queue: InetEventQueue[Millis],
): FastRpcParamsBuffer {.rpcSerializer.} =
  ## called by the socket server every time there's data
  ## on the queue argument given the `rpcEventSubscriber`.
  var ts: Millis

  var resp = %* { "type": "announce" }
  for field, val in fieldPairs(discovery):
    when field != "delay":
      resp[field] = % val

  if queue.tryRecv(ts):
    resp["uptime"] = %(ts.int64.toBiggestFloat() / 1.0e3)
    var jpack = resp.fromJsonNode()
    var ss = MsgBuffer.init(jpack)
    ss.setPosition(jpack.len())
    result = FastRpcParamsBuffer(buf: ss)

proc discoveryStreamer*(
    queue: InetEventQueue[Millis],
    opts: TaskOption[DiscoveryOptions]
) {.rpcThread.} =
  ## Thread example that runs the as a time publisher. This is a reducer
  ## that gathers time samples and outputs arrays of timestamp samples.
  var data = opts.data

  proc setDiscoveryData(): bool =
    try:
      let
        ifdev = getDefaultInterface()
        lladdr: IpAddress = ifdev.linkLocalAddr()

      {.cast(gcsafe).}:
        discovery = DiscoveryData(
          identifier: "",
          fwversion: [1, 0, 0],
          servicePort: data.servicePort.int,
          linkLocal: lladdr.address_v6,
        )
      result = true
    except:
      result = false

  proc sendData(delay: Millis) =
    os.sleep(delay.int)
    var ms = millis()
    var qvals = isolate ms
    discard queue.trySend(qvals)

  while true:
    try: 
      if not setDiscoveryData():
        continue
      for i in 0..<20:
        # start fast
        sendData(100.Millis)
      while true:
        # then slow down
        sendData(data.delay)
    except Exception as err:
      logInfo "discovery stream error: " & err.msg
      os.sleep(1_000)

proc discoveryThread*(arg: ThreadArg[Millis, DiscoveryOptions]) {.thread, nimcall.} = 
  os.sleep(1_000)
  logInfo "discovery thread:", repr(arg.opt.data)
  discoveryStreamer(arg.queue, arg.opt)

