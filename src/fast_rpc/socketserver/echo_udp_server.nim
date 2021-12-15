
import mcu_utils/logging
import ../inet_types

type 
  EchoOpts = ref object
    prompt: string
    selfEchoDisable: bool

proc echoUdpReadHandler*(srv: SocketServerInfo[EchoOpts],
                         result: ReadyKey,
                         sourceClient: Socket,
                         data: EchoOpts) =

  var message = sourceClient.recvLine()

  if message == "":
    raise newException(InetClientDisconnected, "")
  else:
    logDebug("received from client: %s", message)

    for cfd, client in srv.clients:
      if data.selfEchoDisable and cfd == sourceClient.getFd():
        continue
      client.send(data.prompt & message & "\r\L")

proc newEchoUdpServer*(prefix = "", selfEchoDisable = false): SocketServerImpl[EchoOpts] =
  new(result)
  result.readHandler = echoUdpReadHandler
  result.writeHandler = nil 
  result.data = new(EchoOpts) 
  result.data.prompt = prefix
  result.data.selfEchoDisable = selfEchoDisable 