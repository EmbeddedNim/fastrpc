import fast_rpc/socketserver
import fast_rpc/routers/router_fastrpc
import fast_rpc/socketserver/fast_rpc_impl

import std/monotimes
import macros


const
  VERSION = "1.0.0"

# Define RPC Server #
proc rpc_server*(): FastRpcRouter =
  var rt = createRpcRouter()

  rpc(rt, "add") do(a: int, b: int) -> int:
    result = 1 + a + b

  rpc(rt, "addAll") do(vals: seq[int]) -> int:
    for val in vals:
      result = result + val

  rpc(rt, "multAll") do(x: int, vals: seq[int]) -> seq[int]:
    result = newSeqOfCap[int](vals.len())
    for val in vals:
      result.add val * x

  rpc(rt, "echo") do(msg: string) -> string:
    result = "hello: " & msg

  return rt

when isMainModule:
  let inetAddrs = [
    newInetAddr("0.0.0.0", 5656, Protocol.IPPROTO_UDP),
    newInetAddr("0.0.0.0", 5656, Protocol.IPPROTO_TCP),
  ]

  let router = rpc_server()
  startSocketServer(inetAddrs, newFastRpcServer(router, prefixMsgSize=true))
  # var rpc = rpc_server()
  # echo "rpc: ", repr rpc
