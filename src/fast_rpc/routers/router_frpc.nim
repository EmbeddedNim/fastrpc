import tables, strutils, macros, options
import mcu_utils/msgbuffer

import msgpack4nim

import protocol_frpc
export protocol_frpc


proc wrapResponse*(req: FastRpcRequest, ret: MsgBuffer): FastRpcResponse = 
  result.kind = frResponse
  result.id = req.id

proc wrapError*(req: FastRpcRequest, code: int, message: string): FastRpcResponse = 
  result.kind = frError
  result.id = req.id
  var err: FastRpcError
  var ss = MsgBuffer.init()
  ss.pack(err)
  result.params = ss

proc parseError*(ss: MsgBuffer): FastRpcError = 
  ss.unpack(result)

proc parseParams*(ss: MsgBuffer, val: var T) = 
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

# func isEmpty(node: JsonNode): bool = node.isNil or node.kind == JNull
when defined(RpcRouterIncludeTraceBack):
  proc `%`(err: StackTraceEntry): JsonNode =
    # StackTraceEntry = object
    # procname*: cstring         ## Name of the proc that is currently executing.
    # line*: int                 ## Line number of the proc that is currently executing.
    # filename*: cstring         ## Filename of the proc that is currently executing.
    let
      pc: string = $err.procname
      fl: string = $err.filename
      ln: int = err.line.int

    return %* (procname: pc, line: err.line, filename: fl)

proc wrapError*(code: int, msg: string, id: FastRpcId,
                data: JsonNode = newJNull(), err: ref Exception = nil): JsonNode {.gcsafe.} =
  # Create standardised error json
  result = %* { "code": code, "id": id, "message": escapeJson(msg), "data": data }

  when defined(RpcRouterIncludeTraceBack):
    if err != nil:
      result["stacktrace"] = %* err.getStackTraceEntries()
  
  echo "Error generated: ", "result: ", result, " id: ", id

when defined(RpcRouterIncludeTraceBack):
  template wrapException(body: untyped) =
    try:
      body
    except: 
      let msg = getCurrentExceptionMsg()
      echo("control server: invalid input: error: ", msg)
      let resp = rpcInvalidRequest(msg)
      return resp


proc route*(router: RpcRouter, node: JsonNode): JsonNode {.gcsafe.} =
  ## Assumes correct setup of node
  let
    methodName = node[methodField].str
    id = node[idField]
    rpcProc = router.procs.getOrDefault(methodName)

  if rpcProc.isNil:
    let
      methodNotFound = %(methodName & " is not a registered RPC method.")
      error = wrapError(METHOD_NOT_FOUND, "Method not found", id, methodNotFound)
    result = wrapReplyError(id, error)
  else:
    try:
      let jParams = node[paramsField]
      let res = rpcProc(jParams)
      result = wrapReply(id, res)
    except CatchableError as err:
      # echo "Error occurred within RPC", " methodName: ", methodName, "errorMessage = ", err.msg
      let error = wrapError(SERVER_ERROR, methodName & " raised an exception",
                            id, % err.msg[0..<min(err.msg.len(), 128)], err)
      result = wrapReplyError(id, error)
      # echo "Error wrap done "

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
