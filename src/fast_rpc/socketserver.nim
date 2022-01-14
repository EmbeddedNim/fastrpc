import nativesockets
import net
import selectors
import tables
import posix

# export net, selectors, tables, posix

import mcu_utils/logging
import inet_types

export inet_types

proc processWrites[T](selected: ReadyKey, srv: SocketServerInfo[T], data: T) = 
  let (sourceClient, sourceType) = srv.clients[SocketHandle(selected.fd)]
  let data = getData(srv.select, selected.fd)
  if srv.serverImpl.writeHandler != nil:
    srv.serverImpl.writeHandler(srv, selected, sourceClient, sourceType, data)

proc processReads[T](selected: ReadyKey, srv: SocketServerInfo[T], data: T) = 
  let handle = SocketHandle(selected.fd)
  logDebug("processReads:", "selected:fd:", selected.fd)

  if srv.servers.hasKey(handle):
    let server = srv.servers[handle]
    logDebug("process reads on:", "fd:", selected.fd, "srvfd:", server.getFd().int)
    if SocketHandle(selected.fd) == server.getFd():
      var client: Socket = new(Socket)
      server.accept(client)

      client.getFd().setBlocking(false)
      srv.select.registerHandle(client.getFd(), {Event.Read}, data)
      srv.clients[client.getFd()] = (client, SOCK_STREAM)

      let id: int = client.getFd().int
      logDebug("client connected:", "fd:", id)
      return

  if srv.clients.hasKey(SocketHandle(selected.fd)):
    let (sourceClient, sourceType) = srv.clients[SocketHandle(selected.fd)]
    let sourceFd = selected.fd
    let data = getData(srv.select, sourceFd)
    logDebug("srv client:", "fd:", selected.fd, "socktype:", sourceType)

    try:
      if srv.serverImpl.readHandler != nil:
        srv.serverImpl.readHandler(srv, selected, sourceClient, sourceType, data)

    except InetClientDisconnected:
      var client: (Socket, SockType)
      discard srv.clients.pop(sourceFd.SocketHandle, client)
      srv.select.unregister(sourceFd)
      discard posix.close(sourceFd.cint)
      logError("client disconnected: fd: ", $sourceFd)

    except InetClientError:
      srv.clients.del(sourceFd.SocketHandle)
      srv.select.unregister(sourceFd)

      discard posix.close(sourceFd.cint)
      logError("client read error: ", $(sourceFd))

    return

  raise newException(OSError, "unknown socket id: " & $selected.fd.int)

proc startSocketServer*[T](ipaddrs: openArray[InetAddress],
                           serverImpl: SocketServerImpl[T]) =
  # Initialize and setup a new socket server
  var select: Selector[T] = newSelector[T]()
  var servers = newSeq[Socket]()
  var dgramClients = newSeq[(Socket, SockType)]()

  logInfo "SocketServer: starting"
  for ia in ipaddrs:
    logInfo "creating socket on:", "ip:", $ia.host, "port:", $ia.port, $ia.inetDomain(), "sockType:", $ia.socktype, $ia.protocol

    var server = newSocket(
      domain=ia.inetDomain(),
      sockType=ia.socktype,
      protocol=ia.protocol,
      buffered = false
    )
    logDebug "socket started:", "fd:", server.getFd().int

    server.setSockOpt(OptReuseAddr, true)
    server.getFd().setBlocking(false)
    server.bindAddr(ia.port)

    var events: set[Event]
    if ia.protocol in {Protocol.IPPROTO_TCP}:
      server.listen()
      servers.add(server)
      events = {Event.Read}
    elif ia.protocol in {Protocol.IPPROTO_UDP}:
      dgramClients.add((server,SOCK_DGRAM,))
      events = {Event.Read}
    else:
      raise newException(ValueError, "unhandled protocol: " & $ia.protocol)

    select.registerHandle(server.getFd(), events, serverImpl.data)
  
  var srv = createServerInfo[T](select, servers, serverImpl, dgramClients)

  while true:
    var results: seq[ReadyKey] = select.select(-1)
  
    for result in results:
      logDebug "event:", repr(result)
      if Event.Read in result.events:
          result.processReads(srv, serverImpl.data)
      if Event.Write in result.events:
          result.processWrites(srv, serverImpl.data)
    
    if serverImpl.postProcessHandler != nil:
      serverImpl.postProcessHandler(srv, results, serverImpl.data)

  
  select.close()
  for server in servers:
    server.close()