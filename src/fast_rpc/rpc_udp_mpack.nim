import net, selectors, tables, posix

import os
import json
import msgpack4nim/msgpack2json
import mcu_utils/logging
import mcu_utils/basictypes
import nephyr/times

import routers/router_json

import udpsocket

proc handleRpcRequest*(srv: Reactor, rt: RpcRouter, msg: Message) =
  # TODO: improvement
  # The incoming RPC call needs to be less than 1400 or the network buffer size.
  # This could be improved, but is a bit finicky. In my usage, I only send small
  # RPC calls with possibly larger responses. 
  var tu0 = Micros(0)

  logDebug("data from client: ", $(msg.address))
  logDebug("data from client:l: ", msg.data.len())
  tu0 = micros()

  var rcall = msgpack2json.toJsonNode(msg.data)
  logDebug("route rpc", "method: ", $rcall["method"])

  var res: JsonNode = rt.route(rcall)

  var rmsg: string
  logDebug("rpc ran", $rcall["method"])
  rmsg = msgpack2json.fromJsonNode(move res)
  
  let tu3 = micros()

  logInfo "rpc took: ", (tu3 - tu0).int, " us"

  block txres:

    logDebug("rmsg len: ", rmsg.len())
    logDebug("sending len to client: ", $(msg.address))
    srv.sendConfirm(msg.address, rmsg)

const LogNth = 100

proc startRpcUdpServer*(reactor: var Reactor; router: var RpcRouter, delay = Millis(10)) =
  logInfo("starting mpack rpc server")

  var idx = 0

  while true:
    reactor.tick()

    for msg in reactor.takeMessages():
      logInfo "Got a new message:", "id:", msg.id, "len:", msg.data.len(), "mtype:", msg.mtype

      reactor.handleRpcRequest(router, msg)

    if idx mod LogNth == 0:
      logWarn "reactor tick: ", idx

    idx.inc()
    os.sleep(delay.int)

    

