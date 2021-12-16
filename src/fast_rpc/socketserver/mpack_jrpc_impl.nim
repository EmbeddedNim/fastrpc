import sets

import mcu_utils/logging
import ../inet_types
import ../routers/router_json

import json
import msgpack4nim/msgpack2json

export router_json

type 
  JsonRpcOpts* = ref object
    router*: RpcRouter
    bufferSize*: int
    prefixMsgSize*: bool

proc rpcExec*(rt: RpcRouter, msg: var string): string =
  var rcall = msgpack2json.toJsonNode(msg)
  var res: JsonNode = rt.route( rcall )
  result = $res

include common_handlers

proc newMpackJRpcServer*(router: RpcRouter, bufferSize = 1400, prefixMsgSize = false): SocketServerImpl[JsonRpcOpts] =
  new(result)
  result.readHandler = packetRpcHandler
  result.writeHandler = nil 
  result.data = new(JsonRpcOpts) 
  result.data.bufferSize = bufferSize 
  result.data.router = router
  result.data.prefixMsgSize = prefixMsgSize
