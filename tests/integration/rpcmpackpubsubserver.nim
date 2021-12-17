import fast_rpc/routers/router_json_pubsub
import fast_rpc/socketserver
import fast_rpc/socketserver/mpack_jrpc_impl

import std/monotimes
import std/sysrand
import std/os

import mcu_utils/logging

import json
import fast_rpc/inet_types
import msgpack4nim/msgpack2json

const
  VERSION = "1.0.0"

type
  Subscription* = object
    uuid*: array[16, byte]
    okay*: bool

proc run_micros(args: (Subscription, SocketClientSender)) {.gcsafe.} = 
  var (subId, sender) = args
  while true:
    echo "sending mono time: ", "sub: ", $subId, " sender: ", repr(sender)
    let a = getMonoTime().ticks()
    var ts = int(a div 1000)
    var value = %* {"subscription": subId, "result": ts}
    var msg: string = value.fromJsonNode()

    let res = sender(msg)
    if not res: break

# Define RPC Server #
proc rpc_server*(): RpcRouter =
  var rt = createRpcRouter()

  rpc(rt, "version") do() -> string:
    result = VERSION

  rpc(rt, "micros_subscribe") do() -> JsonNode:
    var subid: Subscription
    if urandom(subid.uuid):
      subid.okay = true

    var thr: Thread[(Subscription, SocketClientSender)]
    var arg = (subid, sender)
    createThread(thr, run_micros, arg)

    echo("micros subs done")
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
