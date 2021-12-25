import std/monotimes, std/os, std/json, std/tables

import fast_rpc/socketserver
import fast_rpc/socketserver/mpack_jrpc_impl
import fast_rpc/routers/threaded_subscriptions

import mcu_utils/logging

import fast_rpc/inet_types
import msgpack4nim/msgpack2json

import multicast

const
  VERSION = "1.0.0"

proc multicast_micros(args: JsonRpcSubsArgs) {.gcsafe.} = 
  var subId = args.subid
  let delay = args.data.getInt()
  # var maddr = parseIpAddress "239.2.3.4"
  var maddr = parseIpAddress "172.17.255.255"
  var mport = Port(12346)

  echo("multicast micros subs setup: delay: ", delay)

  var msock = newSocket(
    domain =Domain.AF_INET,
    sockType = SockType.SOCK_DGRAM,
    protocol = Protocol.IPPROTO_UDP,
  )
  logDebug "socket started:", "fd:", msock.getFd().int
  msock.setSockOpt(OptReuseAddr, true)
  msock.enableBroadcast(true)
  msock.bindAddr(mport, address = $maddr)


  let grpres = msock.joinGroup(maddr)
  logDebug "socket joined group:", "maddr:", maddr, "status:", grpres

  while true:
    echo "sending mono time: ", "sub: ", $subId
    let a = getMonoTime().ticks()
    var ts = int(a div 1000)
    var value = %* {"subscription": subId, "result": ts}
    var msg: string = value.fromJsonNode()

    msock.sendTo(maddr, mport, msg)
    os.sleep(delay)

proc run_micros(args: JsonRpcSubsArgs) {.gcsafe.} = 
  var subId = args.subid
  var sender = args.sender
  let delay = args.data.getInt()
  echo("micros subs setup: delay: ", delay)

  while true:
    echo "sending mono time: ", "sub: ", $subId
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

  rpc_subscribe(rt, "micros") do(delay: int) -> JsonNode:
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

  var msubid = newJsonRpcSubsId()
  var margs = JsonRpcSubsArgs(subid: msubid, data: % 1000)
  var mthr: Thread[JsonRpcSubsArgs]
  # createThread(mthr, multicast_micros, margs)

  multicast_micros(margs)

  # let router = rpc_server()
  # startSocketServer(inetAddrs, newMpackJRpcServer(router, prefixMsgSize=true))
