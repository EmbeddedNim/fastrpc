import endians
import sugar

import mcu_utils/logging
import ../inet_types

# type
  # rpcExec[R] = proc (router: R, data: string) {.nimcall.}

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

proc lengthBigendian32*(ln: int): string =
  var sz: int32 = ln.int32
  result = newString(4)
  bigEndian32(result.cstring(), addr sz)

proc lengthFromBigendian32*(datasz: string): int32 =
  result = 0
  bigEndian32(addr result, datasz.cstring())

proc senderClosure*(sourceClient: Socket): SocketClientSender =
  capture sourceClient:
    result =
      proc (data: string): bool =
        try:
          sourceClient.sendSafe(data)
          return true
        except Exception as err:
          logException(err, "run_micros", lvlError)
          return false

proc senderClosure*(sourceClient: Socket, host: IpAddress, port: Port): SocketClientSender =
  capture sourceClient, host, port:
    result =
      proc (data: string): bool =
        try:
          sourceClient.sendTo(host, port, data)
          return true
        except Exception as err:
          logException(err, "run_micros", lvlError)
          return false

template customPacketRpcHandler*(name, rpcExec: untyped): untyped =

  proc `name`*[T](srv: SocketServerInfo[T],
                          result: ReadyKey,
                          sourceClient: Socket,
                          sourceType: SockType,
                          data: T) =
    var
      message = newString(data.bufferSize)
      host: IpAddress
      port: Port

    logInfo("handle json rpc ")
    var sender: SocketClientSender

    # Get network data
    if sourceType == SockType.SOCK_STREAM:
      discard sourceClient.recv(message, data.bufferSize)
      if message == "":
        raise newException(InetClientDisconnected, "")
      sender = senderClosure(sourceClient)
    elif sourceType == SockType.SOCK_DGRAM:
      discard sourceClient.recvFrom(message, message.len(), host, port)
      sender = senderClosure(sourceClient, host, port)
    else:
      raise newException(ValueError, "unhandled socket type: " & $sourceType)

    # process rpc
    var response = `rpcExec`(data.router, message, sender)

    # send response rpc
    if data.prefixMsgSize:
      var datasz = response.len().lengthBigendian32()
      logDebug("sending prefix msg size: ", repr(datasz))
      discard sender(datasz)

    logDebug("msg: data: ", repr(response))
    discard sender(response)

