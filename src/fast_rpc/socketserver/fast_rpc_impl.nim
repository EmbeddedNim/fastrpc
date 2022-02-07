import sets
import json

import mcu_utils/logging
import ../inet_types
import ../socketserver/sockethelpers
import ../routers/router_fastrpc

export router_fastrpc

type 
  FastRpcOpts* = ref object
    router*: FastRpcRouter
    bufferSize*: int
    prefixMsgSize*: bool

proc fastRpcExec*(rt: FastRpcRouter,
                  ss: sink MsgBuffer,
                  clientId: InetClientHandle,
                  ): string =
  logDebug("msgpack processing")
  var rcall: FastRpcRequest
  ss.unpack(rcall)
  var res: FastRpcResponse = rt.route(rcall, clientId)
  var so = MsgBuffer.init(res.result.buf.data.len() + sizeof(res))
  so.pack(res)
  return so.data
  

proc fastRpcReader*(srv: ServerInfo[FastRpcOpts],
                    result: ReadyKey,
                    sock: DataSock,
                    ) =
  var
    buffer = MsgBuffer.init(srv.getInfo().bufferSize)
    host: IpAddress
    port: Port

  buffer.setPosition(0)
  var clientId: InetClientHandle

  # Get network data
  if sock[1] == SockType.SOCK_STREAM:
    discard sock[0].recv(buffer.data, srv.getInfo().bufferSize)
    if buffer.data == "":
      raise newException(InetClientDisconnected, "")
    let
      msglen = buffer.readUintBe16().int
    if buffer.data.len() != 2 + msglen:
      raise newException(OSError, "invalid length: read: " &
                          $buffer.data.len() & " expect: " & $(2 + msglen))
    clientId = newClientHandle(sock[0].getFd())
  elif sock[1] == SockType.SOCK_DGRAM:
    discard sock[0].recvFrom(buffer.data, buffer.data.len(), host, port)
    clientId  = newClientHandle(host, port)
  else:
    raise newException(ValueError, "unhandled socket type: " & $sock[1])

  # process rpc
  let router = srv.getInfo().router
  var response = (router, move buffer, clientId)

  # logDebug("msg: data: ", repr(response))
  # discard reply(response)



proc newFastRpcServer*(router: FastRpcRouter,
                       bufferSize = 1400,
                       prefixMsgSize = false
                       ): Server[FastRpcOpts] =
  result.readHandler = fastRpcReader
  result.writeHandler = nil 
  result.info = FastRpcOpts( 
    bufferSize: bufferSize,
    router: router,
    prefixMsgSize: prefixMsgSize
  )
