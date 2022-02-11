import nativesockets
import net
import selectors
import tables
import posix

# export net, selectors, tables, posix

import mcu_utils/logging
import mcu_utils/inettypes

import servertypes

export servertypes
export inettypes

import sequtils

template withExecHandler(name, handlerProc, blk: untyped) =
  ## check handlerProc isn't nil and handle any unexpected errors
  try:
    if handlerProc != nil:
      let `name` {.inject.} = handlerProc
      `blk`
  except Exception as err:
    logInfo("[SocketServer]::", "unhandled error from server handler: ", repr `handlerProc`)
    logException(err, "socketserver", lvlInfo)
    srv.errorCount.inc()

template withReceiverSocket*(name: untyped, fd: SocketHandle, modname: string, blk: untyped) =
  ## handle checking receiver sockets
  try:
    let `name` {.inject.} = srv.receivers[fd]
    `blk`
  except KeyError:
    logDebug("[SocketServer]::", modname, ":missing socket: ", repr(fd), "skipping")

template withClientSocketErrorCleanups*(socktable: Table[SocketHandle, Socket], key: ReadyKey, blk: untyped) =
  ## handle client socket errors / reading / writing / etc
  try:
    `blk`
  except InetClientDisconnected:
    var client: Socket
    discard `socktable`.pop(key.fd.SocketHandle, client)
    srv.selector.unregister(key.fd)
    discard posix.close(key.fd.cint)
    logError("receiver socket disconnected: fd: ", $key.fd)
  except InetClientError:
    `socktable`.del(key.fd.SocketHandle)
    srv.selector.unregister(key.fd)

    discard posix.close(key.fd.cint)
    logError("receiver socket rx/tx error: ", $(key.fd))


## ============ Socket Server Core Functions ============ ##

proc processEvents[T](srv: ServerInfo[T], selected: ReadyKey) = 
  logDebug("[SocketServer]::", "processUserEvents:", "selected:fd:", selected.fd)
  withExecHandler(eventHandler, srv.impl.eventHandler):
    let evt: SelectEvent = srv.getEvent(selected.fd)
    logDebug("[SocketServer]::", "processUserEvents:", "userEvent:", repr evt)
    # let queue = srv.queues[evt]

    withClientSocketErrorCleanups(srv.receivers, selected):
      eventHandler(srv, evt)

proc processWrites[T](srv: ServerInfo[T], selected: ReadyKey) = 
  logDebug("[SocketServer]::", "processWrites:", "selected:fd:", selected.fd)
  withExecHandler(writeHandler, srv.impl.writeHandler):
    withReceiverSocket(sourceClient, selected.fd.SocketHandle, "processWrites"):
      withClientSocketErrorCleanups(srv.receivers, selected):
        writeHandler(srv, sourceClient)

proc processReads[T](srv: ServerInfo[T], selected: ReadyKey) = 
  logDebug("[SocketServer]::", "\n")
  logDebug("[SocketServer]::", "processReads:", "selected:fd:", selected.fd)
  logDebug("[SocketServer]::", "processReads:", "listners:fd:", srv.listners.keys().toSeq().mapIt(it.int()).repr())
  logDebug("[SocketServer]::", "processReads:", "receivers:fd:", srv.receivers.keys().toSeq().mapIt(it.int()).repr())

  if srv.listners.hasKey(selected.fd.SocketHandle):
    let server = srv.listners[selected.fd.SocketHandle]
    logDebug("process connect on listner:", "fd:", selected.fd,
              "srvfd:", server.getFd().int)
    if SocketHandle(selected.fd) == server.getFd():
      var client: Socket = new(Socket)
      server.accept(client)
      client.getFd().setBlocking(false)
      srv.receivers[client.getFd()] = client
      let id: int = client.getFd().int
      logDebug("client connected:", "fd:", id)
      registerHandle(srv.selector, client.getFd(), {Event.Read}, initFdKind(SOCK_STREAM))
  elif srv.receivers.hasKey(SocketHandle(selected.fd)):
    logDebug("srv client:", "fd:", selected.fd)
    withExecHandler(readHandler, srv.impl.readHandler):
      withReceiverSocket(sourceClient, selected.fd.SocketHandle, "processReads"):
        withClientSocketErrorCleanups(srv.receivers, selected):
          readHandler(srv, sourceClient) 
  else:
    raise newException(OSError, "unknown socket type: fd: " & repr selected)

proc startSocketServer*[T](ipaddrs: openArray[InetAddress],
                           serverImpl: Server[T]) =
  # Setup and run a new SocketServer.
  var select: Selector[FdKind] = newSelector[FdKind]()
  var listners = newSeq[Socket]()
  var receivers = newSeq[Socket]()

  logInfo "[SocketServer]::", "starting"
  for ia in ipaddrs:
    logInfo "[SocketServer]::", "creating socket on:", "ip:", $ia.host, "port:", $ia.port, $ia.inetDomain(), "sockType:", $ia.socktype, $ia.protocol

    var socket = newSocket(
      domain=ia.inetDomain(),
      sockType=ia.socktype,
      protocol=ia.protocol,
      buffered = false
    )
    logDebug "[SocketServer]::", "socket started:", "fd:", socket.getFd().int

    socket.setSockOpt(OptReuseAddr, true)
    socket .getFd().setBlocking(false)
    socket.bindAddr(ia.port)

    var evts: set[Event]
    var stype: SockType

    if ia.protocol in {Protocol.IPPROTO_TCP}:
      socket.listen()
      listners.add(socket)
      stype = SOCK_STREAM
      evts = {Event.Read}
    elif ia.protocol in {Protocol.IPPROTO_UDP}:
      receivers.add(socket)
      stype = SOCK_DGRAM
      evts = {Event.Read}
    else:
      raise newException(ValueError, "unhandled protocol: " & $ia.protocol)

    registerHandle(select, socket.getFd(), evts, initFdKind(stype))
  
  for event in serverImpl.events:
    logDebug "[SocketServer]::", "userEvent:register:", repr(event)
    registerEvent(select, event, initFdKind(event))

  var srv = newServerInfo[T](serverImpl, select, listners, receivers)

  while true:
    var keys: seq[ReadyKey] = select.select(-1)
    logDebug "[SocketServer]::", "keys:", repr(keys)
  
    for key in keys:
      logDebug "[SocketServer]::", "key:", repr(key)
      if Event.Read in key.events:
          srv.processReads(key)
      if Event.User in key.events:
          srv.processEvents(key)
      if Event.Write in key.events:
          srv.processWrites(key)
    
    if serverImpl.postProcessHandler != nil:
      serverImpl.postProcessHandler(srv, keys)

  
  select.close()
  for listner in srv.listners.values():
    listner.close()