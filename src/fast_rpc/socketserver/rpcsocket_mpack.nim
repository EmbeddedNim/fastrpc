import net, selectors, tables, posix

import json
import msgpack4nim/msgpack2json
import mcu_utils/logging

import tcpsocket

proc rpcMsgPackWriteHandler*(srv: TcpServerInfo[RpcRouter], result: ReadyKey, sourceClient: Socket, rt: RpcRouter) =
  raise newException(OSError, "the request to the OS failed")

proc rpcMsgPackReadHandler*(srv: TcpServerInfo[RpcRouter], result: ReadyKey, sourceClient: Socket, rt: RpcRouter) =
  # TODO: improvement
  # The incoming RPC call needs to be less than 1400 or the network buffer size.
  # This could be improved, but is a bit finicky. In my usage, I only send small
  # RPC calls with possibly larger responses. 

  try:
    logDebug("rpc server handler: router: %x", rt.buffer)

    var rcall: JsonNode
    var tu0 = Micros(0)

    block rxmsg:
      var msg = sourceClient.recv(rt.buffer, -1)

      tu0 = micros()

      if msg.len() == 0:
        raise newException(TcpClientDisconnected, "")
      else:
        logDebug("data from client: ", $(sourceClient.getFd().int))
        logDebug("data from client:l: ", msg.len())
        rcall = msgpack2json.toJsonNode(msg)
        logDebug("done parsing mpack ")

    var res: JsonNode
    block pres:
        logDebug("route rpc message: ", )
        logDebug("method: ", $rcall["method"])
        logDebug("route rpc route: ", )
        res = rt.route(rcall)

    var rmsg: string
    block prmsg:
        logDebug("call ran", )
        rmsg = msgpack2json.fromJsonNode(move res)
    
    let tu3 = micros()

    # echo "rpc took: ", tu3 - tu0, " us"

    block txres:

        logDebug("rmsg len: ", rmsg.len())
        logDebug("sending len to client: ", $(sourceClient.getFd().int))
        sourceClient.sendLength(rmsg)
        logDebug("sending data to client: ", $(sourceClient.getFd().int))
        sourceClient.sendChunks(rmsg)

  except TimeoutError:
    echo("control server: error: socket timeout: ", $sourceClient.getFd().int)

proc startRpcSocketServer*(port: Port; router: var RpcRouter) =
  logInfo("starting mpack rpc server: buffer: %s", $router.buffer)

  startSocketServer[RpcRouter](
    port=port,
    ipaddrs=[IPv4_any()],
    readHandler=rpcMsgPackReadHandler,
    writeHandler=rpcMsgPackWriteHandler,
    data=router)
    
