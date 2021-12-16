import sets
import json
import msgpack4nim/msgpack2json

import mcu_utils/logging
import ../inet_types
import ../routers/router_json_pubsub

import common_handlers

export router_json_pubsub

type 
  JsonRpcOpts* = ref object
    router*: RpcRouter
    bufferSize*: int
    prefixMsgSize*: bool

proc mpackJrpcExec*(rt: RpcRouter, msg: var string, sender: SocketClientSender): string =
  logDebug("msgpack processing")
  var rcall = msgpack2json.toJsonNode(msg)
  var res: JsonNode = rt.route(rcall, sender)
  result = res.fromJsonNode()

customPacketRpcHandler(packetMpackJRpcHandler, mpackJrpcExec, fromJsonNode)

proc newMpackJRpcServer*(router: RpcRouter, bufferSize = 1400, prefixMsgSize = false): SocketServerImpl[JsonRpcOpts] =
  new(result)
  result.readHandler = packetMpackJRpcHandler
  result.writeHandler = nil 
  result.data = new(JsonRpcOpts) 
  result.data.bufferSize = bufferSize 
  result.data.router = router
  result.data.prefixMsgSize = prefixMsgSize
