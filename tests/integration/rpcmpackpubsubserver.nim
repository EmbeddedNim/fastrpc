import fast_rpc/routers/router_json_pubsub
import fast_rpc/socketserver
import fast_rpc/socketserver/mpack_jrpc_impl

import std/monotimes
import std/sysrand

const
  VERSION = "1.0.0"

type
  Subscription* = object
    uuid*: array[16, byte]
    okay*: bool


proc run_micros(sub: (Subscription, SocketClientSender)) = 
  while true:
    let a = getMonoTime().ticks()
    var ts = int(a div 1000)


# Define RPC Server #
proc rpc_server*(): RpcRouter =
  var rt = createRpcRouter()

  rpc(rt, "version") do() -> string:
    result = VERSION

  rpc(rt, "micros_subscribe") do() -> Subscription:
    if urandom(result.uuid):
      result.okay = true

    var thr: Thread[(Subscription, SocketClientSender)]
    var arg = (result, sender)
    createThread(thr, run_micros, arg)

  rpc(rt, "add") do(a: int, b: int) -> int:
    result = a + b

  return rt

when isMainModule:
  let inetAddrs = [
    newInetAddr("0.0.0.0", 5555, Protocol.IPPROTO_UDP),
    newInetAddr("0.0.0.0", 5555, Protocol.IPPROTO_TCP),
  ]

  let router = rpc_server()
  startSocketServer(inetAddrs, newMpackJRpcServer(router, prefixMsgSize=true))
