import sets

import mcu_utils/logging
import ../inet_types

type 
  EchoOpts = ref object
    knownClients: HashSet[InetAddress]
    prompt: string
    selfEchoDisable: bool

proc echoUdpReadHandler*(srv: SocketServerInfo[EchoOpts],
                         result: ReadyKey,
                         sourceClient: Socket,
                         data: EchoOpts) =
  var
    message = newString(1400)
  var
    address: IpAddress
    port: Port

  let cnt =
    sourceClient.recvFrom(message, message.len(), address, port)

  if message == "":
    raise newException(InetClientDisconnected, "")
  else:
    data.knownClients.incl(InetAddress(host: address, port: port))
    logDebug("received from client:", message)

    for ia in data.knownClients:
      # if data.selfEchoDisable and cfd == sourceClient.getFd():
        # continue
      sourceClient.sendTo(ia.host, ia.port, data.prompt & message & "\r\n")

proc newEchoUdpServer*(prefix = "", selfEchoDisable = false): SocketServerImpl[EchoOpts] =
  new(result)
  result.readHandler = echoUdpReadHandler
  result.writeHandler = nil 
  result.data = new(EchoOpts) 
  result.data.knownClients = initHashSet[InetAddress]()
  result.data.prompt = prefix
  result.data.selfEchoDisable = selfEchoDisable 
