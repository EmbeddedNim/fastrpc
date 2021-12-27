import sets
import json
import msgpack4nim/msgpack2json

import mcu_utils/logging
import ../inet_types
import ../routers/router_fastrpc

import common_handlers

export router_fastrpc

type 
  JsonRpcOpts* = ref object
    router*: FastRpcRouter
    bufferSize*: int
    prefixMsgSize*: bool

proc fastRpcExec*(rt: FastRpcRouter,
                  ss: sink MsgBuffer,
                  sender: SocketClientSender
                  ): string =
  logDebug("msgpack processing")
  var rcall: FastRpcRequest
  ss.unpack(rcall)
  logDebug("msgpack rcall:", rcall)
  var res: FastRpcResponse = rt.route(rcall, sender)
  var so = MsgBuffer.init(res.result.buf.data.len() + 100)
  so.pack(res)
  return so.data
  

customPacketRpcHandler(packetRpcHandler, fastRpcExec)

proc newFastRpcServer*(router: FastRpcRouter,
                       bufferSize = 1400,
                       prefixMsgSize = false
                       ): SocketServerImpl[JsonRpcOpts] =
  new(result)
  result.readHandler = packetRpcHandler
  result.writeHandler = nil 
  result.data = new(JsonRpcOpts) 
  result.data.bufferSize = bufferSize 
  result.data.router = router
  result.data.prefixMsgSize = prefixMsgSize
