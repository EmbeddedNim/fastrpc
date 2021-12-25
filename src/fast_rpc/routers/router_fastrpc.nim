import tables, strutils, macros
import mcu_utils/msgbuffer

import msgpack4nim
export msgpack4nim

import msgpack4nim/msgpack2json

import protocol_frpc
export protocol_frpc

proc wrapResponse*(id: FastRpcId, resp: FastRpcParamsBuffer): FastRpcResponse = 
  result.kind = frResponse
  result.id = id
  result.result = resp

proc wrapResponseError*(id: FastRpcId, err: FastRpcError): FastRpcResponse = 
  result.kind = frError
  result.id = id
  var ss = MsgBuffer.init()
  ss.pack(err)
  result.result = (buf: ss)

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
  dumpAllocstats:
    block:
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
          let errobj = FastRpcError(code: SERVER_ERROR, msg: procName & " raised an exception")
          result = wrapResponseError(id, errobj)

proc makeProcName(s: string): string =
  result = ""
  for c in s:
    if c.isAlphaNumeric: result.add c

proc hasReturnType(params: NimNode): bool =
  if params != nil and params.len > 0 and params[0] != nil and
     params[0].kind != nnkEmpty:
    result = true

iterator paramsIter(params: NimNode): tuple[name, ntype: NimNode] =
  for i in 1 ..< params.len:
    let arg = params[i]
    let argType = arg[^2]
    for j in 0 ..< arg.len-2:
      yield (arg[j], argType)

proc mkParamsVars*(paramsIdent, paramsType, params: NimNode): NimNode =
  if params.isNil: return

  result = newStmtList()
  var varList = newSeq[NimNode]()
  for paramid, paramType in paramsIter(params):
    varList.add quote do:
      var `paramid`: `paramType` = `paramsIdent`.`paramid`
  result.add varList
  # echo "paramsSetup return:\n", treeRepr result

proc mkParamsType*(paramsIdent, paramsType, params: NimNode): NimNode =
  if params.isNil: return

  var typObj = quote do:
    type
      `paramsType` = object
  var recList = newNimNode(nnkRecList)
  for paramIdent, paramType in paramsIter(params):
    # processing multiple variables of one type
    recList.add newIdentDefs(postfix(paramIdent, "*"), paramType)
  typObj[0][2][2] = recList
  result = typObj
  # echo "paramsParser return:\n", treeRepr result

macro rpc*(server: FastRpcRouter, path: string, body: untyped): untyped =
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
    # procs are generated from the stripped path
    pathStr = $path
    # strip non alphanumeric
    procNameStr = pathStr.makeProcName
    # public rpc proc
    procName = ident(procNameStr)
    # parameter type name
    paramsIdent = genSym(nskParam, "args")
    paramTypeName = ident("RpcType_" & procNameStr)
    # when parameters present: proc that contains our rpc body
    # objIdent = ident("paramObj")
    doMain = ident(procNameStr & "DoMain")
    # async result
    # res = newIdentNode("result")
    # errJson = newIdentNode("errJson")
  var
    paramSetups = mkParamsVars(paramsIdent, paramTypeName, parameters)
    paramTypes = mkParamsType(paramsIdent, paramTypeName, parameters)
    procBody = if body.kind == nnkStmtList: body else: body.body

  let ReturnType = if parameters.hasReturnType: parameters[0]
                   else: ident "FastRpcParamsBuffer"

  # delegate async proc allows return and setting of result as native type
  result.add quote do:
    `paramTypes`

    proc `doMain`(`paramsIdent`: `paramTypeName`, context: SocketClientSender): `ReturnType` =
      {.cast(gcsafe).}:
        `paramSetups`
        `procBody`

  result.add quote do:
    proc `procName`(params: FastRpcParamsBuffer,
                    context: SocketClientSender
                    ): FastRpcParamsBuffer {.gcsafe, nimcall.} =
      var obj: `paramTypeName`
      params.buf.setPosition(0)
      var js = MsgStream.init(params.buf.data)
      params.buf.unpack(obj)

      let res = `doMain`(obj, context)
      var ss = MsgBuffer.init()
      ss.pack(res)
      result = (buf: ss)


  result.add quote do:
    `server`.register(`path`, `procName`)

  # when defined(nimDumpRpcs):
    # echo "\n", pathStr, ": ", result.repr

  echo "rpc return:\n", repr result
