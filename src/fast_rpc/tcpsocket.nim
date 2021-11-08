import nativesockets
import net
import selectors
import tables
import posix

export net, selectors, tables, posix
import macros
import sequtils

# import chronicles 

# macro logger*(args: varargs[untyped]) =
#   var prints = newSeq[NimNode]()
#   for arg in args:
#     let a = 
#       if arg.kind == nnkExprEqExpr:
#         let arg1 = arg[1]
#         quote do: $(`arg1`)
#       else: 
#         quote do: $(`arg`)
#     prints.add(a)
#   result = newCall(newIdentNode("echo"), prints)

# template error*(args: varargs[untyped]) =
#   discard "ignore"
#   logger args
# template debug*(args: varargs[untyped]) =
#   discard "ignore"
#   logger args
# template info*(args: varargs[untyped]) =
#   discard "ignore"
#   logger args

import std/logging

var mylogger = newConsoleLogger()

macro dologs*(lvl, args: varargs[untyped]) =
  var prints = newSeq[NimNode]()
  for arg in args:
    let a = 
      if arg.kind == nnkExprEqExpr:
        let arg1 = arg[1]
        quote do: $(`arg1`)
      else: 
        quote do: $(`arg`)
    prints.add(a)
  var ml = quote do: mylogger
  prints.insert(lvl, 0)
  prints.insert(ml, 0)
  result = newCall("log", prints)
  echo "RESULT: ", treeRepr result

template error*(args: varargs[untyped]) =
  discard "ignore"
  dologs(lvlError, args)
template debug*(args: varargs[untyped]) =
  discard "ignore"
  dologs(lvlDebug, args)
template info*(args: varargs[untyped]) =
  discard "ignore"
  dologs(lvlInfo, args)

const
  MsgChunk {.intdefine.} = 1400

type 
  TcpClientDisconnected* = object of OSError
  TcpClientError* = object of OSError

template sendWrap*(socket: Socket, data: untyped) =
  # Checks for disconnect errors when sending
  # This makes it easy to handle dirty disconnects
  try:
    socket.send(data)
  except OSError as err:
    if err.errorCode == ENOTCONN:
      var etcp = newException(TcpClientDisconnected, "")
      etcp.errorCode = err.errorCode
      raise etcp

    else:
      raise err


proc sendChunks*(sourceClient: Socket, rmsg: string) =
  let rN = rmsg.len()
  # debug("rpc handler send client: %d bytes", rN)
  var i = 0
  while i < rN:
    var j = min(i + MsgChunk, rN) 
    # debug("rpc handler sending: i: %s j: %s ", $i, $j)
    var sl = rmsg[i..<j]
    sourceClient.sendWrap(move sl)
    i = j

proc sendLength*(sourceClient: Socket, rmsg: string) =
  var rmsgN: int = rmsg.len()
  var rmsgSz = newString(4)
  for i in 0..3:
    rmsgSz[i] = char(rmsgN and 0xFF)
    rmsgN = rmsgN shr 8

  sourceClient.sendWrap(move rmsgSz)

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
  debug("process reads on: ", fd = selected.fd)
  for server in srv.servers:
    if SocketHandle(selected.fd) == server.getFd():
      var client: Socket = new(Socket)
      server.accept(client)

      client.getFd().setBlocking(false)
      srv.select.registerHandle(client.getFd(), {Event.Read}, data)
      srv.clients[client.getFd()] = client

      let id: int = client.getFd().int
      debug("client connected: %d", id)
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
      error("client disconnected: fd: ", sourceFd)

    except TcpClientError as err:
      srv.clients.del(sourceFd.SocketHandle)
      srv.select.unregister(sourceFd)

      discard posix.close(sourceFd.cint)
      error("client read error: ", sourceFd)

    return

  raise newException(OSError, "unknown socket id: " & $selected.fd.int)


proc echoReadHandler*(srv: TcpServerInfo[string], result: ReadyKey, sourceClient: Socket, data: string) =
  var message = sourceClient.recvLine()

  if message == "":
    raise newException(TcpClientDisconnected, "")

  else:
    debug("received msg: ", message)

    for cfd, client in srv.clients:
      # if sourceClient.getFd() == cfd.getFd():
        # continue
      client.sendWrap(data & message & "\r\L")

proc startSocketServer*[T](port: Port, ipaddrs: openArray[IpAddress], readHandler: TcpServerHandler[T], writeHandler: TcpServerHandler[T], data: var T) =
  var select: Selector[T] = newSelector[T]()
  var servers = newSeq[Socket]()
  for ipaddr in ipaddrs:
    info "Server: starting "
    let domain = if ipaddr.family == IpAddressFamily.IPv6: Domain.AF_INET6 else: Domain.AF_INET6 
    # var server: Socket = newSocket(domain=domain)
    var server: Socket = newSocket()

    server.setSockOpt(OptReuseAddr, true)
    server.getFd().setBlocking(false)
    server.bindAddr(port)
    server.listen()
    servers.add server

    info "Server: started on: ip: ", ipaddr, port
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

when isMainModule:
  var data = ""
  startSocketServer(Port(5555), ipaddrs=[IPv6_any()], readHandler=echoReadHandler, writeHandler=nil, data=data)
