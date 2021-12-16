import nativesockets, net, selectors, posix, tables

export nativesockets, net, selectors, posix, tables

type
  InetAddress* = object
    # Combined type for a remote IP address and service port
    host*: IpAddress
    port*: Port
    protocol*: net.Protocol
    socktype*: net.SockType

  SocketServerInfo*[T] = ref object 
    select*: Selector[T]
    servers*: ref Table[SocketHandle, Socket]
    clients*: ref Table[SocketHandle, (Socket, SockType)]
    serverImpl*: SocketServerImpl[T]

  SocketServerHandler*[T] = proc (srv: SocketServerInfo[T],
                                  selected: ReadyKey,
                                  client: Socket,
                                  clientType: SockType,
                                  data: T) {.nimcall.}

  SocketServerProcessor*[T] = proc (srv: SocketServerInfo[T], results: seq[ReadyKey], data: T) {.nimcall.}

  SocketServerImpl*[T] = ref object
    data*: T
    readHandler*: SocketServerHandler[T]
    writeHandler*: SocketServerHandler[T]
    postProcessHandler*: SocketServerProcessor[T]

type 
  InetClientDisconnected* = object of OSError
  InetClientError* = object of OSError

proc newInetAddr*(host: string, port: int, protocol = net.IPPROTO_TCP): InetAddress =
  result.host = parseIpAddress(host)
  result.port = Port(port)
  result.protocol = protocol
  result.socktype = protocol.toSockType()

proc createServerInfo*[T](selector: Selector[T],
                          servers: seq[Socket],
                          serverImpl: SocketServerImpl,
                          clients: seq[(Socket, SockType)] = @[]
                          ): SocketServerInfo[T] = 
  result = new(SocketServerInfo[T])
  result.select = selector
  result.serverImpl = serverImpl
  result.servers = newTable[SocketHandle, Socket]()
  result.clients = newTable[SocketHandle, (Socket, SockType)]()

  for server in servers:
    result.servers[server.getFd()] = server
  for (client, ctype) in clients:
    result.clients[client.getFd()] = (client, ctype)

proc inetDomain*(inetaddr: InetAddress): nativesockets.Domain = 
  case inetaddr.host.family:
  of IpAddressFamily.IPv4:
    result = Domain.AF_INET
  of IpAddressFamily.IPv6:
    result = Domain.AF_INET6 