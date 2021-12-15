
import mcu_utils/logging
import ../inet_types

proc echoTcpReadHandler*(srv: SocketServerInfo[string],
                      result: ReadyKey,
                      sourceClient: Socket,
                      data: string) =

  var message = sourceClient.recvLine()

  if message == "":
    raise newException(InetClientDisconnected, "")

  else:
    logDebug("received from client: %s", message)

    for cfd, client in srv.clients:
      client.send(data & message & "\r\L")

proc newEchoTcpServer*(prefix = ""): SocketServerImpl[string] =
  new(result)
  result.readHandler = echoTcpReadHandler
  result.writeHandler = nil 
  result.data = prefix 
