import router
import ../servertypes
import ../socketserver

export router, servertypes, socketserver


type 
  FastRpcOpts* = ref object
    router*: FastRpcRouter
    bufferSize*: int
    prefixMsgSize*: bool
    # inetQueue*: seq[InetMsgQueue]
    task*: Thread[FastRpcRouter]

## =================== Handle RPC Events =================== ##

proc fastRpcInetReplies*(
        srv: ServerInfo[FastRpcOpts],
        queue: InetMsgQueue,
      ) =
  logDebug("fastRpcEventHandler:eventHandler:")
  var item: InetMsgQueueItem
  while queue.tryRecv(item):
    logDebug("fastRpcEventHandler:item: ", repr(item))
    case item.cid[].kind:
    of clSocket:
      withReceiverSocket(sock, item.cid[].fd, "fasteventhandler"):
        var msg: MsgBuffer = item.data[]
        logDebug("fastRpcEventHandler:sock: ", repr(sock.getFd()))
        var lenBuf = newString(2)
        lenBuf.toStrBe16(msg.data.len().int16)
        sock.sendSafe(lenBuf & msg.data)
    of clAddress:
      var sock = srv.receivers[item.cid[].fd]
      logDebug("fastRpcEventHandler:sock: ", repr(sock.getFd()))
    of clCanBus:
      raise newException(Exception, "TODO: canbus sender")
    of clEmpty:
      raise newException(Exception, "empty inet handle")

proc fastRpcEventHandler*(
        srv: ServerInfo[FastRpcOpts],
        evt: SelectEvent,
      ) =
  logDebug("fastRpcEventHandler:eventHandler:")
  let router = srv.getOpts().router

  logDebug("fastRpcEventHandler:loop")

  if evt == router.outQueue.evt:
    srv.fastRpcInetReplies(router.outQueue)
  elif evt == router.registerQueue.evt:
    logDebug("fastRpcEventHandler:registerQueue: ", repr(evt))
  elif evt in router.eventProcs:
    logDebug("fastRpcEventHandler:eventProcs: ", repr(evt))
  else:
    raise newException(ValueError, "unknown queue event: " & repr(evt))

## =================== Read RPC Tasks =================== ##
proc fastRpcReadHandler*(
        srv: ServerInfo[FastRpcOpts],
        sock: Socket,
      ) =
  var
    buffer = newQMsgBuffer(srv.getOpts().bufferSize)
    host: IpAddress
    port: Port

  logDebug("server:fastRpcReadHandler:")
  var clientId: InetClientHandle

  # Get network data
  let fdkind = srv.selector.getData(sock.getFd())
  let stype: SockType = fdkind.getSockType().get()

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
  logDebug("readHandler:router: buffer: ", repr(buffer))

  let res = router.inQueue.trySendMsg(clientId, buffer)
  if not res:
    logInfo("readHandler:router:send: dropped ")
  logDebug("readHandler:router:inQueue: ", repr(router.inQueue.chan.peek()))

## =================== Execute RPC Tasks =================== ##
proc fastRpcExec*(router: FastRpcRouter, item: InetMsgQueueItem): bool =
  logDebug("readHandler:router: inQueue: ", repr(router.inQueue.chan.peek()))
  logDebug("fastrpcTask:item: ", repr(item))

  var response = router.callMethod(item.data[], item.cid)
  logDebug("fastrpcTask:sent:response: ", repr(response))
  result = router.outQueue.trySendMsg(item.cid, response)


proc fastRpcTask*(router: FastRpcRouter) {.thread.} =
  logInfo("Starting FastRpc Task")
  logDebug("fastrpcTask:inQueue:chan: ", repr(router.inQueue.chan.addr().pointer))

  var status = true
  while status:
    logDebug("fastrpcTask:loop: ")
    let item: InetMsgQueueItem = router.inQueue.recv()
    let res = router.fastRpcExec(item)
    logDebug("fastrpcTask:sent:res: ", repr(res))

proc postServerProcessor(srv: ServerInfo[FastRpcOpts], results: seq[ReadyKey]) =
  var item: InetMsgQueueItem 
  let router = srv.impl.opts.router
  while router.inQueue.tryRecv(item):
    let res = router.fastRpcExec(item)
    logDebug("fastrpcProcessor:processed:sent:res: ", repr(res))


## =================== Fast RPC Server Implementation =================== ##
proc newFastRpcServer*(router: FastRpcRouter,
                       bufferSize = 1400,
                       prefixMsgSize = false,
                       threaded = false,
                       ): Server[FastRpcOpts] =
  new(result)
  result.readHandler = fastRpcReadHandler
  result.eventHandler = fastRpcEventHandler 
  result.writeHandler = nil 
  result.opts = FastRpcOpts(
    bufferSize: bufferSize,
    router: router,
    prefixMsgSize: prefixMsgSize
  )

  let
    inQueue = InetMsgQueue.init(size=8)
    outQueue = InetMsgQueue.init(size=8)
    registerQueue = RpcSubIdQueue.init(size=8)
  
  result.opts.router.inQueue = inQueue
  result.opts.router.outQueue = outQueue
  result.opts.router.registerQueue = registerQueue

  # result.opts.inetQueue = @[outQueue]
  result.events = @[
    outQueue.evt,
  ] 

  logDebug("newFastRpcServer:outQueue:evt: ", repr(router.outQueue.evt))
  logDebug("newFastRpcServer:inQueue:evt: ", repr(router.inQueue.evt))
  logDebug("newFastRpcServer:inQueue:chan: ", repr(router.inQueue.chan.addr().pointer))
  if threaded:
    # create n-threads
    createThread(result.opts.task, fastRpcTask, router)
  else:
    # use current thread to handle rpcs
    result.postProcessHandler = postServerProcessor 
