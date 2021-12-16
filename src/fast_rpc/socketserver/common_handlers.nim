import endians
import mcu_utils/logging
import ../inet_types

# type
  # rpcExec[R] = proc (router: R, data: string) {.nimcall.}

proc sendWrap(socket: Socket, data: string) =
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
    sourceClient.sendWrap(move sl)
    i = j

proc lengthBigendian(ln: int): string =
  var sz: int32 = ln.int32
  result = newString(4)
  bigEndian32(result.cstring(), addr sz)

proc sendLength*(sourceClient: Socket, rmsg: string) =
  sourceClient.sendWrap(rmsg.len().lengthBigendian())

proc packetRpcHandler*[T](srv: SocketServerInfo[T],
                         result: ReadyKey,
                         sourceClient: Socket,
                         sourceType: SockType,
                         data: T) =
  var
    message = newString(data.bufferSize)
    host: IpAddress
    port: Port

  logInfo("handle json rpc ")
  # Get network data
  if sourceType == SockType.SOCK_STREAM:
    discard sourceClient.recv(message, data.bufferSize)
    if message == "":
      raise newException(InetClientDisconnected, "")
  elif sourceType == SockType.SOCK_DGRAM:
    discard sourceClient.recvFrom(message, message.len(), host, port)
  else:
    raise newException(ValueError, "unhandled socket type: " & $sourceType)

  # process rpc
  var response = rpcExec(data.router, message)
  if data.prefixMsgSize:
    var datasz = response.len().lengthBigendian()
    logInfo("prefix msg size: ", repr(datasz))
    response = datasz & response

  # Send network data
  if sourceType == SockType.SOCK_STREAM:
    sourceClient.send(response)
  elif sourceType == SockType.SOCK_DGRAM:
    sourceClient.sendTo(host, port, response)
  else:
    raise newException(ValueError, "unhandled socket type: " & $sourceType)
