import router
import ../socketserver

import ../socketservers/sockethelpers

export router, socketserver


type 
  FastRpcOpts* = ref object
    router*: FastRpcRouter
    bufferSize*: int
    prefixMsgSize*: bool
    input*: Chan[FastRpcParamsBuffer]
    output*: Chan[FastRpcParamsBuffer]
    task*: Thread[FastRpcRouter]

proc fastRpcEventHandler*(
        srv: ServerInfo[FastRpcOpts],
        key: ReadyKey,
        sock: Socket,
      ) =
  logDebug("fastrpc:eventHandler:")
  raise newException(Exception, "TODO")

proc fastRpcReadHandler*(
        srv: ServerInfo[FastRpcOpts],
        key: ReadyKey,
        sock: Socket,
      ) =
  var
    buffer = newUniquePtr(MsgBuffer.init(srv.getOpts().bufferSize))
    host: IpAddress
    port: Port

  logDebug("server:fastRpcReadHandler:")
  var clientId: InetClientHandle

  # Get network data
  let stype: SockType = srv.selector.getData(sock.getFd())

  if stype == SockType.SOCK_STREAM:
    discard sock.recv(buffer[].data, srv.getOpts().bufferSize)
    if buffer[].data == "":
      raise newException(InetClientDisconnected, "")
    let
      msglen = buffer[].readUintBe16().int
    if buffer[].data.len() != 2 + msglen:
      raise newException(OSError, "invalid length: read: " &
                          $buffer[].data.len() & " expect: " & $(2 + msglen))
    clientId = newClientHandle(sock.getFd())
  elif stype == SockType.SOCK_DGRAM:
    discard sock.recvFrom(buffer[].data, buffer[].data.len(), host, port)
    clientId  = newClientHandle(host, port)
  else:
    raise newException(ValueError, "unhandled socket type: " & $stype)

  # process rpc
  let router = srv.getOpts().router
  # var response = fastRpcExec(router, buffer, clientId)

  # logDebug("msg: data: ", repr(response))
  router.inQueue.send(clientId, buffer)
  logDebug("readHandler:router: inQueue: ", repr(router.inQueue.chan.peek()))

proc fastRpcTask*(router: FastRpcRouter) =
  logInfo("Starting FastRpc Task")

  var status = true
  while status:
    logInfo("fastrpcTask:loop")
    let item: RpcQueueItem = router.inQueue.recv()
    logInfo("fastrpcTask:item: ", repr(item))

    var response = router.callMethod(item.data[], item.cid)
    logInfo("fastrpcTask:sent:response: ", repr(response))
    let res = router.outQueue.trySend(item.cid, response)
    logInfo("fastrpcTask:sent:res: ", repr(res))


proc newFastRpcServer*(router: FastRpcRouter,
                       bufferSize = 1400,
                       prefixMsgSize = false
                       ): Server[FastRpcOpts] =
  result.readHandler = fastRpcReadHandler
  result.eventHandler = fastRpcEventHandler 
  result.writeHandler = nil 
  result.postProcessHandler = nil 
  result.opts = FastRpcOpts( 
    bufferSize: bufferSize,
    router: router,
    prefixMsgSize: prefixMsgSize
  )
  result.opts.router.inQueue = newRpcQueue(size=10)
  result.opts.router.outQueue = newRpcQueue(size=10)
  # result.opts.task = createThread(router)
