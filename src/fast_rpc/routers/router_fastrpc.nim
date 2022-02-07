import tables, strutils, macros, os

import mcu_utils/basictypes
import mcu_utils/msgbuffer
import mcu_utils/logging
include mcu_utils/threads

import msgpack4nim
export msgpack4nim

import msgpack4nim/msgpack2json

import protocol_frpc
export protocol_frpc
export Millis

proc wrapResponse*(id: FastRpcId, resp: FastRpcParamsBuffer, kind = frResponse): FastRpcResponse = 
  result.kind = kind
  result.id = id
  result.result = resp

proc wrapResponseError*(id: FastRpcId, err: FastRpcError): FastRpcResponse = 
  result.kind = frError
  result.id = id
  var ss = MsgBuffer.init()
  ss.pack(err)
  result.result = (buf: ss)

proc wrapResponseError*(id: FastRpcId, code: FastErrorCodes, msg: string, err: ref Exception, stacktraces: bool): FastRpcResponse = 
  let errobj = FastRpcError(code: SERVER_ERROR, msg: msg)
  if stacktraces and not err.isNil():
    errobj.trace = @[]
    for se in err.getStackTraceEntries():
      let file: string = rsplit($(se.filename), '/', maxsplit=1)[^1]
      errobj.trace.add( ($se.procname, file, se.line, ) )
  result = wrapResponseError(id, errobj)

proc parseError*(ss: MsgBuffer): FastRpcError = 
  ss.unpack(result)

proc parseParams*[T](ss: MsgBuffer, val: var T) = 
  ss.unpack(val)

proc createRpcRouter*(): FastRpcRouter =
  result = new(FastRpcRouter)
  result.procs = initTable[string, FastRpcProc]()

proc register*(router: var FastRpcRouter, path: string, call: FastRpcProc) =
  router.procs[path] = call
  echo "registering: ", path

proc sysRegister*(router: var FastRpcRouter, path: string, call: FastRpcProc) =
  router.sysprocs[path] = call
  echo "registering: sys: ", path

proc clear*(router: var FastRpcRouter) =
  router.procs.clear

proc hasMethod*(router: FastRpcRouter, methodName: string): bool =
  router.procs.hasKey(methodName)

proc route*(router: FastRpcRouter,
            req: FastRpcRequest,
            client: InetClientHandle,
            ): FastRpcResponse {.gcsafe.} =
    ## Route's an rpc request. 
    # dumpAllocstats:
    var rpcProc: FastRpcProc 
    case req.kind:
    of frRequest:
      rpcProc = router.procs.getOrDefault(req.procName)
    of frSystemRequest:
      rpcProc = router.sysprocs.getOrDefault(req.procName)
    of frSubscribe:
      rpcProc = router.procs.getOrDefault(req.procName)
    else:
      result = wrapResponseError(
                  req.id,
                  SERVER_ERROR,
                  "unimplemented request typed",
                  nil, 
                  router.stacktraces)

    if rpcProc.isNil:
      let msg = req.procName & " is not a registered RPC method."
      let err = FastRpcError(code: METHOD_NOT_FOUND, msg: msg)
      result = wrapResponseError(req.id, err)
    else:
      try:
        # Handle rpc request the `context` variable is different
        # based on whether the rpc request is a system/regular/subscription
        var ctx = RpcContext(id: req.id, client: client, router: router)
        let res: FastRpcParamsBuffer = rpcProc(req.params, ctx)
        result = FastRpcResponse(kind: frResponse, id: req.id, result: res)
      except ObjectConversionDefect as err:
        result = wrapResponseError(
                    req.id,
                    INVALID_PARAMS,
                    req.procName & " raised an exception",
                    err, 
                    router.stacktraces)
      except CatchableError as err:
        result = wrapResponseError(
                    req.id,
                    INTERNAL_ERROR,
                    req.procName & " raised an exception",
                    err, 
                    router.stacktraces)
