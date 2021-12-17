import std/monotimes, std/os, std/json, std/tables

import fast_rpc/socketserver
import fast_rpc/socketserver/mpack_jrpc_impl
import fast_rpc/routers/threaded_subscriptions

import mcu_utils/logging

import fast_rpc/inet_types
import msgpack4nim/msgpack2json

const
  VERSION = "1.0.0"

proc run_micros(args: JsonRpcSubsArgs) {.gcsafe.} = 
  var subId = args.subid
  var sender = args.sender
  let delay = args.data.getInt()
  echo("micros subs setup: delay: ", delay)

  while true:
    echo "sending mono time: ", "sub: ", $subId, " sender: ", repr(sender)
    let a = getMonoTime().ticks()
    var ts = int(a div 1000)
    var value = %* {"subscription": subId, "result": ts}
    var msg: string = value.fromJsonNode()

    let res = sender(msg)
    if not res: break
    os.sleep(delay)

# Define RPC Server #
proc rpc_server*(): RpcRouter =
  var rt = createRpcRouter()
  var subs = JsonRpcSubThreadTable()

  rpc(rt, "version") do() -> string:
    result = VERSION

  rpc_subscribe(rt, "micros_subscribe") do(delay: int) -> JsonNode:
    var subid = subs.subscribeWithThread(context, run_micros, % delay)
    echo("micros subs called: ", delay)
    result = % subid

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
