
import mcu_utils/logging
import ../inet_types
import ../routers/router_json

import hashes
import json

type
  rpcExec[R] = proc (router: R, data: string) {.nimcall.}

proc packetRpcHandler*[T](srv: SocketServerInfo[T],
                         result: ReadyKey,
                         sourceClient: Socket,
                         sourceType: SockType,
                         data: T) =
  var
    message = newString(data.bufferSize)

  case sourceType:
  of SockType.SOCK_STREAM:
    discard sourceClient.recv(message, data.bufferSize)
    if message == "":
      raise newException(InetClientDisconnected, "")
    logDebug("received from client:", message)

    var response = rpcExec(data.router, message)
    sourceClient.send(response)

  of SockType.SOCK_DGRAM:
    var
      host: IpAddress
      port: Port

    discard sourceClient.recvFrom(message, message.len(), host, port)
    var response = rpcExec(data.router, message)
    sourceClient.sendTo(host, port, response)

  else:
    raise newException(ValueError, "unhandled socket type: " & $sourceType)
