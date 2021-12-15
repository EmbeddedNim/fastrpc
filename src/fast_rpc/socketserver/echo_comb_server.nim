import sets

import mcu_utils/logging
import ../inet_types

type 
  EchoOpts = ref object
    knownClients: HashSet[InetAddress]
    prompt: string

proc sendAllClients*(srv: SocketServerInfo[EchoOpts],
                     data: EchoOpts,
                     sourceClient: Socket,
                     sourceType: SockType,
                     message: string) =

  var msg = data.prompt & message & "\r\n"

  # tcp clients
  for cfd, client in srv.clients:
    if client[1] == SockType.SOCK_STREAM:
      client[0].send(msg)

  # udp clients
  for ia in data.knownClients:
    sourceClient.sendTo(ia.host, ia.port, msg)

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


proc echoUdpReadHandler*(srv: SocketServerInfo[EchoOpts],
                         result: ReadyKey,
                         sourceClient: Socket,
                         sourceType: SockType,
                         data: EchoOpts) =
  
  var
    message = newString(1400)
    address: IpAddress
    port: Port

  discard sourceClient.recvFrom(message, message.len(), address, port)

  if message == "":
    raise newException(InetClientDisconnected, "")
  else:
    data.knownClients.incl(InetAddress(host: address, port: port))
    logDebug("received from client:", message)

    srv.sendAllClients(data, sourceClient, sourceType, message)

proc echoReadHandler*(srv: SocketServerInfo[EchoOpts],
                         result: ReadyKey,
                         sourceClient: Socket,
                         sourceType: SockType,
                         data: EchoOpts) =
  if sourceType == SockType.SOCK_STREAM:
    echoTcpReadHandler(srv, result, sourceClient, sourceType, data)
  elif sourceType == SockType.SOCK_DGRAM:
    echoUdpReadHandler(srv, result, sourceClient, sourceType, data)
  
proc newEchoServer*(prefix = "", selfEchoDisable = false): SocketServerImpl[EchoOpts] =
  new(result)
  result.readHandler = echoUdpReadHandler
  result.writeHandler = nil 
  result.data = new(EchoOpts) 
  result.data.knownClients = initHashSet[InetAddress]()
  result.data.prompt = prefix
