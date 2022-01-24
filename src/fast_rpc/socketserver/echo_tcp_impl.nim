
import mcu_utils/logging
import ../inet_types
import ../socketserver/sockethelpers

type 
  EchoOpts = ref object
    prompt: string
    selfEchoDisable: bool

proc echoTcpReadHandler*(srv: SocketServerInfo[EchoOpts],
                         result: ReadyKey,
                         sourceClient: Socket,
                         sourceType: SockType,
                         data: EchoOpts) =

  var message = sourceClient.recvLine()

  if message == "":
    raise newException(InetClientDisconnected, "")
  else:
    logDebug("received from client: %s", message)

    for cfd, client in srv.clients:
      if data.selfEchoDisable and cfd == sourceClient.getFd():
        continue
      client[0].send(data.prompt & message & "\r\L")

proc newEchoTcpServer*(prefix = "", selfEchoDisable = false): SocketServerImpl[EchoOpts] =
  new(result)
  result.readHandler = echoTcpReadHandler
  result.writeHandler = nil 
  result.postProcessHandler = nil 
  result.data = new(EchoOpts) 
  result.data.prompt = prefix
  result.data.selfEchoDisable = selfEchoDisable 
