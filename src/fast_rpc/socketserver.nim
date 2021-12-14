import nativesockets
import net
import selectors
import tables
import posix

# export net, selectors, tables, posix

import mcu_utils/logging

const
  MsgChunk {.intdefine.} = 1400

template sendWrap*(socket: Socket, data: untyped) =
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

type
  TcpServerInfo*[T] = ref object 
    select*: Selector[T]
    servers*: seq[Socket]
    clients*: ref Table[SocketHandle, Socket]
    writeHandler*: TcpServerHandler[T]
    readHandler*: TcpServerHandler[T]

  TcpServerHandler*[T] = proc (srv: TcpServerInfo[T], selected: ReadyKey, client: Socket, data: T) {.nimcall.}


proc createServerInfo[T](selector: Selector[T], servers: seq[Socket]): TcpServerInfo[T] = 
  result = new(TcpServerInfo[T])
  result.servers = servers
  result.select = selector
  result.clients = newTable[SocketHandle, Socket]()

proc processWrites[T](selected: ReadyKey, srv: TcpServerInfo[T], data: T) = 
  var sourceClient: Socket = newSocket(SocketHandle(selected.fd))
  let data = getData(srv.select, selected.fd)
  if srv.writeHandler != nil:
    srv.writeHandler(srv, selected, sourceClient, data)

proc processReads[T](selected: ReadyKey, srv: TcpServerInfo[T], data: T) = 
  for server in srv.servers:
    logDebug("process reads on:", "fd:", selected.fd, "srvfd:", server.getFd().int)
    if SocketHandle(selected.fd) == server.getFd():
      var client: Socket = new(Socket)
      server.accept(client)

      client.getFd().setBlocking(false)
      srv.select.registerHandle(client.getFd(), {Event.Read}, data)
      srv.clients[client.getFd()] = client

      let id: int = client.getFd().int
      logDebug("client connected: %d", id)
      return

  if srv.clients.hasKey(SocketHandle(selected.fd)):
    let sourceClient: Socket = newSocket(SocketHandle(selected.fd))
    let sourceFd = selected.fd
    let data = getData(srv.select, sourceFd)

    try:
      if srv.readHandler != nil:
        srv.readHandler(srv, selected, sourceClient, data)

    except TcpClientDisconnected as err:
      var client: Socket
      discard srv.clients.pop(sourceFd.SocketHandle, client)
      srv.select.unregister(sourceFd)
      discard posix.close(sourceFd.cint)
      logError("client disconnected: fd: ", $sourceFd)

    except TcpClientError as err:
      srv.clients.del(sourceFd.SocketHandle)
      srv.select.unregister(sourceFd)

      discard posix.close(sourceFd.cint)
      logError("client read error: ", $(sourceFd))

    return

  raise newException(OSError, "unknown socket id: " & $selected.fd.int)


proc startSocketServer*[T](port: Port, ipaddrs: openArray[IpAddress], readHandler: TcpServerHandler[T], writeHandler: TcpServerHandler[T], data: var T) =
  var select: Selector[T] = newSelector[T]()
  var servers = newSeq[Socket]()
  for ipaddr in ipaddrs:
    logInfo "Server: starting "
    let domain = if ipaddr.family == IpAddressFamily.IPv6: Domain.AF_INET6 else: Domain.AF_INET6 
    # var server: Socket = newSocket(domain=domain)
    var server: Socket = newSocket()

    server.setSockOpt(OptReuseAddr, true)
    server.getFd().setBlocking(false)
    server.bindAddr(port)
    server.listen()
    servers.add server

    logInfo "Server: started on: ip: ", $ipaddr, " port: ", $port
    select.registerHandle(server.getFd(), {Event.Read}, data)
  
  var srv = createServerInfo[T](select, servers)
  srv.readHandler = readHandler
  srv.writeHandler = writeHandler

  while true:
    var results: seq[ReadyKey] = select.select(-1)
  
    for result in results:
      if Event.Read in result.events:
          result.processReads(srv, data)
      if Event.Write in result.events:
          result.processWrites(srv, data)
      # taskYIELD()
    # delayMillis(1)
    # vTaskDelay(1.TickType_t)

  
  select.close()
  for server in servers:
    server.close()

# when isMainModule:
  # startSocketServer(Port(5555), readHandler=echoReadHandler, writeHandler=nil)