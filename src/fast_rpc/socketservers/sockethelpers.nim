import endians
import sugar
import os

import mcu_utils/logging
import mcu_utils/msgbuffer
import ../inet_types

type
  ServerInfo*[T] = ref object 
    ## Represents type for the select/epoll based socket server
    impl*: Server[T]
    selector*: Selector[T]

    listners*: Table[SocketHandle, Socket]
    receivers*: Table[SocketHandle, (Socket, SockType)]
    producers*: Table[SocketHandle, (Socket, SockType)]

  DataSock* = (Socket, SockType)

  ServerHandler*[T] = proc (srv: ServerInfo[T],
                            selected: ReadyKey,
                            sock: DataSock,
                            ) {.nimcall.}

  ServerProcessor*[T] = proc (srv: ServerInfo[T],
                              results: seq[ReadyKey],
                              ) {.nimcall.}

  Server*[T] = object
    info*: T
    readHandler*: ServerHandler[T]
    writeHandler*: ServerHandler[T]
    postProcessHandler*: ServerProcessor[T]

  SocketClientMessage* = ref object
    ss: MsgBuffer

proc getInfo*[T](srv: ServerInfo[T]): T =
  result = srv.impl.info

proc createServerInfo*[T](
          serverImpl: Server,
          selector: Selector[T],
          listners: seq[Socket],
          receivers: seq[(Socket, SockType)],
          producers: seq[(Socket, SockType)],
        ): ServerInfo[T] = 
  result = new(ServerInfo[T])
  result.impl = serverImpl
  result.select = selector
  result.listners = initTable[SocketHandle, Socket]()
  result.receivers = initTable[SocketHandle, (Socket, SockType)]()
  result.producers = initTable[SocketHandle, (Socket, SockType)]()

  # handle socket based listners (e.g. tcp)
  for listner in listners:
    result.listners[listner.getFd()] = listner
  # handle any packet receiver's (e.g. udp, can)
  for (receiver, ctype) in receivers:
    result.receivers[receiver.getFd()] = (receiver, ctype)

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
