import endians
import sugar
import os

import mcu_utils/logging
import mcu_utils/msgbuffer
import ../inet_types

type
  SocketServerInfo*[T] = ref object 
    ## Represents type for the select/epoll based socket server
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

  SocketClientMessage* = ref object
    ss: MsgBuffer

  SocketClientSender* = proc (data: string): bool {.closure, gcsafe.}

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

proc sendSafe*(socket: Socket, data: string) =
  # Checks for disconnect errors when sending
  # This makes it easy to handle dirty disconnects
  try:
    socket.send(data)
  except OSError as err:
    if err.errorCode == ENOTCONN:
      var etcp = newException(InetClientDisconnected, "")
      etcp.errorCode = err.errorCode
      raise etcp
    else:
      raise err

proc sendChunks*(sourceClient: Socket, rmsg: string, chunksize: int) =
  let rN = rmsg.len()
  logDebug("rpc handler send client: bytes:", rN)
  var i = 0
  while i < rN:
    var j = min(i + chunksize, rN) 
    var sl = rmsg[i..<j]
    sourceClient.sendSafe(move sl)
    i = j

proc toStrBe16*(str: var string, ln: int16) =
  var sz: int32 = ln.int16
  bigEndian16(str.cstring(), addr sz)
proc toStrBe16*(ln: int16): string =
  result = newString(2)
  result.toStrBe16(ln)
proc fromStrBe16*(datasz: string): int16 =
  assert datasz.len() >= 2
  bigEndian16(addr result, datasz.cstring())

proc newSocketPair*(sockType: SockType = SockType.SOCK_STREAM,
                    protocol: Protocol = Protocol.IPPROTO_IP,
                    domain: Domain = Domain.AF_UNIX,
                    buffered = true,
                   ): (Socket, Socket) =
  ## create socket pairing 

  dump([toInt(domain), toInt(sockType), toInt(protocol)])
  var socketFds: array[2, cint]
  let status = posix.socketpair(
                             toInt(domain),
                             toInt(sockType),
                             toInt(protocol),
                             socketFds)
  if status != 0: 
    raise newException(OSError, "error making socket pair: " &
      osErrorMsg(OSErrorCode(status)))

  result[0] = newSocket(SocketHandle(socketFds[0]), domain,
                        sockType, protocol, buffered)
  result[1] = newSocket(SocketHandle(socketFds[1]), domain,
                        sockType, protocol, buffered)
