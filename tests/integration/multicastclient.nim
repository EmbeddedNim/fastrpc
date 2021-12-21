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

proc listen_multicast_micros*(args: JsonRpcSubsArgs) {.gcsafe.} = 
  var subId = args.subid
  var sender = args.sender
  let delay = args.data.getInt()
  var maddr = parseIpAddress "0.0.0.0"
  # var mport = Port(8905)
  var mport = Port(12346)

  echo("multicast micros subs setup: delay: ", delay)

  var msock = newSocket(
    domain =Domain.AF_INET,
    sockType = SockType.SOCK_DGRAM,
    protocol = Protocol.IPPROTO_UDP,
    buffered = false
  )
  msock.setSockOpt(OptReuseAddr, true)
  msock.bindAddr(mport)

  logDebug "socket started:", "fd:", msock.getFd().int
  let grpres = joinGroup(msock, maddr)
  logDebug "socket joined group:", "maddr:", maddr, "status:", grpres

  while true:
    echo "reading mono time: ", "sub: ", $subId

    var dl = 1400
    var data = newString(dl)
    var claddr: IpAddress
    var clport: Port
    discard msock.recvFrom(data, dl, claddr, clport)

    echo "read time: ", "len:", dl, "data:", repr(data)
    os.sleep(delay)


when isMainModule:

  var msubid = newJsonRpcSubsId()
  var margs = JsonRpcSubsArgs(subid: msubid, data: % 1000)
  listen_multicast_micros(margs)

