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

proc lengthBigendian16*(ln: int16): string =
  var sz: int32 = ln.int16
  result = newString(2)
  bigEndian16(result.cstring(), addr sz)

proc lengthFromBigendian16*(datasz: string): int16 =
  assert datasz.len() >= 2
  result = 0
  bigEndian16(addr result, datasz.cstring())

proc senderClosure*(sourceClient: Socket): SocketClientSender =
  capture sourceClient:
    result =
      proc (data: string): bool =
        try:
          var datasz = data.len().int16.lengthBigendian16()
          sourceClient.sendSafe(datasz & data)
          return true
        except OSError:
          raise newException(InetClientDisconnected, "client error")
        except Exception as err:
          logException(err, "socker sender:", lvlError)
          return false


proc senderClosure*(sourceClient: Socket, host: IpAddress, port: Port): SocketClientSender =
  capture sourceClient, host, port:
    result =
      proc (data: string): bool =
        try:
          sourceClient.sendTo(host, port, data)
          return true
        except OSError:
          raise newException(InetClientDisconnected, "client error")
        except Exception as err:
          logException(err, "socket sender:", lvlError)
          return false

template customPacketRpcHandler*(name, rpcExec: untyped): untyped =

  proc `name`*[T](srv: SocketServerInfo[T],
                          result: ReadyKey,
                          sourceClient: Socket,
                          sourceType: SockType,
                          data: T) =
    var
      buffer = MsgBuffer.init(data.bufferSize)
      host: IpAddress
      port: Port

    buffer.setPosition(0)
    var sender: SocketClientSender

    # Get network data
    if sourceType == SockType.SOCK_STREAM:
      discard sourceClient.recv(buffer.data, data.bufferSize)
      if buffer.data == "":
        raise newException(InetClientDisconnected, "")
      let
        msglen = buffer.readUintBe16().int
      if buffer.data.len() != 2 + msglen:
        raise newException(OSError, "invalid length: read: " & $buffer.data.len() & " expect: " & $(2 + msglen))
      sender = senderClosure(sourceClient)
    elif sourceType == SockType.SOCK_DGRAM:
      discard sourceClient.recvFrom(buffer.data, buffer.data.len(), host, port)
      sender = senderClosure(sourceClient, host, port)
    else:
      raise newException(ValueError, "unhandled socket type: " & $sourceType)

    # process rpc
    var response = `rpcExec`(data.router, move buffer, sender)

    # logDebug("msg: data: ", repr(response))
    discard sender(response)

