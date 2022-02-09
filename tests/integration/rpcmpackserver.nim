import fastrpc/socketserver
import fastrpc/socketserver/mpack_jrpc_impl

import std/monotimes

const
  VERSION = "1.0.0"

# Define RPC Server #
proc rpc_server*(): RpcRouter =
  var rt = createRpcRouter()

  rpc(rt, "version") do() -> string:
    result = VERSION

  rpc(rt, "micros") do() -> int:
    let a = getMonoTime().ticks()
    result = int(a div 1000)

  rpc(rt, "add") do(a: int, b: int) -> int:
    result = a + b

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
    newInetAddr("0.0.0.0", 5555, Protocol.IPPROTO_UDP),
    newInetAddr("0.0.0.0", 5555, Protocol.IPPROTO_TCP),
  ]

  let router = rpc_server()
  startSocketServer(inetAddrs, newMpackJRpcServer(router, prefixMsgSize=true))
