import sets
import json

import mcu_utils/logging
import ../inet_types
import ../routers/router_json

include common_handlers

type 
  JsonRpcOpts* = ref object
    router*: RpcRouter
    bufferSize*: int

proc jsonRpc*(rt: RpcRouter, msg: var string): string =
  var rcall: JsonNode = parseJson(msg)
  var res: JsonNode = rt.route( rcall )
  result = $res

proc newJsonRpcServer*(router: RpcRouter, bufferSize = 1400): SocketServerImpl[JsonRpcOpts] =
  new(result)
  result.readHandler = packetRpcHandler[JsonRpcOpts]
  result.writeHandler = nil 
  result.data = new(JsonRpcOpts) 
  result.data.bufferSize = bufferSize 
  result.data.router = router
