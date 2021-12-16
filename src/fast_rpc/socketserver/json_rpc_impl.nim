import sets

import mcu_utils/logging
import ../inet_types
import ../routers/router_json

import hashes
import json


type 
  JsonRpcOpts = ref object
    router: RpcRouter
    bufferSize: int

proc jsonHandler*(rt: RpcRouter, msg: var string): string =
  var rcall: JsonNode = parseJson(msg)
  var res: JsonNode = rt.route( rcall )
  result = $res

proc jsonRpcHandler*(srv: SocketServerInfo[JsonRpcOpts],
                         result: ReadyKey,
                         sourceClient: Socket,
                         sourceType: SockType,
                         data: JsonRpcOpts) =
  logDebug("echoReadHandler:", "sourceClient:", sourceClient.getFd().int, "socktype:", sourceType)
  var
    message = newString(data.bufferSize)

  case sourceType:
  of SockType.SOCK_STREAM:
    discard sourceClient.recv(message, data.bufferSize)
    if message == "":
      raise newException(InetClientDisconnected, "")
    logDebug("received from client:", message)

    var response = jsonHandler(data.router, message)
    sourceClient.send(response)

  of SockType.SOCK_DGRAM:
    var
      host: IpAddress
      port: Port

    discard sourceClient.recvFrom(message, message.len(), host, port)
    var response = jsonHandler(data.router, message)
    sourceClient.sendTo(host, port, response)

  else:
    raise newException(ValueError, "unhandled socket type: " & $sourceType)

proc newJsonRpcServer*(router: RpcRouter, bufferSize = 1400): SocketServerImpl[JsonRpcOpts] =
  new(result)
  result.readHandler = jsonRpcHandler
  result.writeHandler = nil 
  result.data = new(JsonRpcOpts) 
  result.data.bufferSize = bufferSize 
  result.data.router = router
