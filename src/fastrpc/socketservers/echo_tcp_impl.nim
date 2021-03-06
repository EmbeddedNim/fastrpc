
import mcu_utils/logging
import mcu_utils/inettypes
import ../servertypes

type 
  EchoOpts = ref object
    prompt: string
    selfEchoDisable: bool

proc echoTcpReadHandler*(srv: ServerInfo[EchoOpts],
                         sourceClient: Socket,
                         ) =

  var message = sourceClient.recvLine()

  if message == "":
    raise newException(InetClientDisconnected, "")
  else:
    logDebug("received from client: %s", message)

    for cfd, client in srv.receivers:
      if srv.impl.opts.selfEchoDisable and cfd == sourceClient.getFd():
        continue
      client.send(srv.impl.opts.prompt & message & "\r\L")

proc newEchoTcpServer*(prefix = "", selfEchoDisable = false): Server[EchoOpts] =
  new(result)
  result.readHandler = echoTcpReadHandler
  result.writeHandler = nil 
  result.postProcessHandler = nil 
  result.opts = new(EchoOpts) 
  result.opts.prompt = prefix
  result.opts.selfEchoDisable = selfEchoDisable 
