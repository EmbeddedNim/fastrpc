import sets

import mcu_utils/logging
import ../inet_types

import hashes

type 
  EchoOpts = ref object
    knownClients: HashSet[(InetAddress, Socket)]
    prompt: string

proc hash*(sock: Socket): Hash = hash(sock.getFd())

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

  logDebug("sendAllClients:", $data.knownClients)
  # udp clients
  for (ia, client) in data.knownClients:
    client.sendTo(ia.host, ia.port, msg)

proc echoReadHandler*(srv: SocketServerInfo[EchoOpts],
                         result: ReadyKey,
                         sourceClient: Socket,
                         sourceType: SockType,
                         data: EchoOpts) =
  logDebug("echoReadHandler:", "sourceClient:", sourceClient.getFd().int, "socktype:", sourceType)
  case sourceType:
  of SockType.SOCK_STREAM:
    var message = sourceClient.recvLine()

    if message == "":
      raise newException(InetClientDisconnected, "")
    else:
      logDebug("received from client:", message)
      srv.sendAllClients(data, sourceClient, sourceType, message)

  of SockType.SOCK_DGRAM:
    var
      message = newString(1400)
      address: IpAddress
      port: Port

    discard sourceClient.recvFrom(message, message.len(), address, port)

    if message == "":
      raise newException(InetClientDisconnected, "")
    else:
      data.knownClients.incl((InetAddress(host: address, port: port), sourceClient))
      logDebug("received from client:", message)

      srv.sendAllClients(data, sourceClient, sourceType, message)
  else:
    raise newException(ValueError, "unhandled socket type: " & $sourceType)

  
proc newEchoServer*(prefix = "", selfEchoDisable = false): SocketServerImpl[EchoOpts] =
  new(result)
  result.readHandler = echoReadHandler
  result.writeHandler = nil 
  result.data = new(EchoOpts) 
  result.data.knownClients = initHashSet[(InetAddress, Socket)]()
  result.data.prompt = prefix
