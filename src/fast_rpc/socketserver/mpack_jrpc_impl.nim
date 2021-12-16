import sets

import mcu_utils/logging
import ../inet_types
import ../routers/router_json

import json
import msgpack4nim/msgpack2json

type 
  JsonRpcOpts* = ref object
    router*: RpcRouter
    bufferSize*: int

proc mpackHandler*(rt: RpcRouter, msg: var string): string =
  var rcall = msgpack2json.toJsonNode(msg)
  var res: JsonNode = rt.route( rcall )
  result = $res

proc mpackJRpcHandler*(srv: SocketServerInfo[JsonRpcOpts],
                         result: ReadyKey,
                         sourceClient: Socket,
                         sourceType: SockType,
                         data: JsonRpcOpts) =
  var
    message = newString(data.bufferSize)

  case sourceType:
  of SockType.SOCK_STREAM:
    discard sourceClient.recv(message, data.bufferSize)
    if message == "":
      raise newException(InetClientDisconnected, "")

    var response = mpackHandler(data.router, message)
    sourceClient.send(response)

  of SockType.SOCK_DGRAM:
    var
      host: IpAddress
      port: Port

    discard sourceClient.recvFrom(message, message.len(), host, port)
    var response = mpackHandler(data.router, message)
    sourceClient.sendTo(host, port, response)

  else:
    raise newException(ValueError, "unhandled socket type: " & $sourceType)

proc newMpackJRpcServer*(router: RpcRouter, bufferSize = 1400): SocketServerImpl[JsonRpcOpts] =
  new(result)
  result.readHandler = mpackJRpcHandler
  result.writeHandler = nil 
  result.data = new(JsonRpcOpts) 
  result.data.bufferSize = bufferSize 
  result.data.router = router
