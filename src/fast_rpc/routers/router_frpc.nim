import tables, strutils, macros
import mcu_utils/msgbuffer

import msgpack4nim

import protocol_frpc
export protocol_frpc

proc wrapResponse*(id: FastRpcId, resp: FastRpcParamsBuffer): FastRpcResponse = 
  result.kind = frResponse
  result.id = id
  result.params = resp

proc wrapResponseError*(id: FastRpcId, err: FastRpcError): FastRpcResponse = 
  result.kind = frError
  result.id = id
  var ss = MsgBuffer.init()
  ss.pack(err)
  result.params = (buf: ss)

proc parseError*(ss: MsgBuffer): FastRpcError = 
  ss.unpack(result)

proc parseParams*[T](ss: MsgBuffer, val: var T) = 
  ss.unpack(val)

proc createRpcRouter*(): FastRpcRouter =
  result = new(FastRpcRouter)
  result.procs = initTable[string, FastRpcProc]()

proc register*(router: var FastRpcRouter, path: string, call: FastRpcProc) =
  router.procs[path] = call

proc clear*(router: var FastRpcRouter) =
  router.procs.clear

proc hasMethod*(router: FastRpcRouter, methodName: string): bool =
  router.procs.hasKey(methodName)

proc emptySender(data: string): bool = false

proc route*(router: FastRpcRouter,
            req: FastRpcRequest,
            sender: SocketClientSender = emptySender
            ): FastRpcResponse {.gcsafe.} =
  ## Routes and calls the fast rpc
  let
    rpcProc = router.procs.getOrDefault(req.procName)
    id = req.id
    procName = req.procName
    params = req.params

  if rpcProc.isNil:
    let
      msg = req.procName & " is not a registered RPC method."
      err = FastRpcError(code: METHOD_NOT_FOUND, msg: msg)
    result = wrapResponseError(id, err)
  else:
    try:
      let res: FastRpcParamsBuffer = rpcProc(params, sender)
      result = FastRpcResponse(kind: frResponse, id: id, result: res)
    except CatchableError:
      # TODO: fix wrapping exception...
      let errobj: FastRpcError = nil
      result = wrapResponseError(id, SERVER_ERROR, procName & " raised an exception", errobj)

proc makeProcName(s: string): string =
  result = ""
  for c in s:
    if c.isAlphaNumeric: result.add c

proc hasReturnType(params: NimNode): bool =
  if params != nil and params.len > 0 and params[0] != nil and
     params[0].kind != nnkEmpty:
    result = true

macro rpc*(server: RpcRouter, path: string, body: untyped): untyped =
  ## Define a remote procedure call.
  ## Input and return parameters are defined using the ``do`` notation.
  ## For example:
  ## .. code-block:: nim
  ##    myServer.rpc("path") do(param1: int, param2: float) -> string:
  ##      result = $param1 & " " & $param2
  ##    ```
  ## Input parameters are automatically marshalled from json to Nim types,
  ## and output parameters are automatically marshalled to json for transport.
  result = newStmtList()
  let
    parameters = body.findChild(it.kind == nnkFormalParams)
    # all remote calls have a single parameter: `params: JsonNode`
    paramsIdent = newIdentNode"params"
    # procs are generated from the stripped path
    pathStr = $path
    # strip non alphanumeric
    procNameStr = pathStr.makeProcName
    # public rpc proc
    procName = newIdentNode(procNameStr)
    # when parameters present: proc that contains our rpc body
    doMain = newIdentNode(procNameStr & "DoMain")
    # async result
    # res = newIdentNode("result")
    # errJson = newIdentNode("errJson")
  var
    # setup = jsonToNim(parameters, paramsIdent)
    procBody = if body.kind == nnkStmtList: body else: body.body

  let ReturnType = if parameters.hasReturnType: parameters[0]
                   else: ident "JsonNode"

  # delegate async proc allows return and setting of result as native type
  result.add quote do:
    proc `doMain`(`paramsIdent`: JsonNode): `ReturnType` =
      {.cast(gcsafe).}:
        `setup`
        `procBody`

  if ReturnType == ident"JsonNode":
    # `JsonNode` results don't need conversion
    result.add quote do:
      proc `procName`(`paramsIdent`: JsonNode): JsonNode {.gcsafe.} =
        return `doMain`(`paramsIdent`)
  else:
    result.add quote do:
      proc `procName`(`paramsIdent`: JsonNode): JsonNode {.gcsafe.} =
        return %* `doMain`(`paramsIdent`)


  result.add quote do:
    `server`.register(`path`, `procName`)

  when defined(nimDumpRpcs):
    echo "\n", pathStr, ": ", result.repr
