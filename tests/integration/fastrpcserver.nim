import fast_rpc/routers/router_frpc

import std/monotimes
import macros

const
  VERSION = "1.0.0"

var rt = createRpcRouter()
rpc(rt, "add") do(a: int, b: int) -> int:
  echo $(a + b)

# Define RPC Server #
proc rpc_server*(): FastRpcRouter =
  var rt = createRpcRouter()

  # rpc(rt, "add") do(a: int, b: int) -> int:
    # result = a + b

  return rt

var rpc = rpc_server()
echo "rpc: ", repr rpc
