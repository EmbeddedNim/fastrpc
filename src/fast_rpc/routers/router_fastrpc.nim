import tables, strutils, macros
import mcu_utils/msgbuffer

import msgpack4nim
export msgpack4nim

import msgpack4nim/msgpack2json

import protocol_frpc
export protocol_frpc

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
  echo "registering: ", path

proc register*(router: var FastRpcRouter, path: string, call: FastRpcSysProc) =
  router.sysprocs[path] = call
  echo "registering: sys: ", path

proc clear*(router: var FastRpcRouter) =
  router.procs.clear

proc hasMethod*(router: FastRpcRouter, methodName: string): bool =
  router.procs.hasKey(methodName)

proc emptySender(data: string): bool = false

proc handleRoute*[P](
            rpcProc: P,
            router: FastRpcRouter,
            req: FastRpcRequest,
            sender: SocketClientSender = emptySender
            ): FastRpcResponse {.gcsafe.} =

      if rpcProc.isNil:
        let
          msg = req.procName & " is not a registered RPC method."
          err = FastRpcError(code: METHOD_NOT_FOUND, msg: msg)
        result = wrapResponseError(req.id, err)
      else:
        try:
          when typeof(rpcProc) is FastRpcSysProc:
            let ctx = RpcSystemContext(sender: sender, router: router)
            let res: FastRpcParamsBuffer = rpcProc(req.params, ctx)
          else:
            let res: FastRpcParamsBuffer = rpcProc(req.params, sender)
          result = FastRpcResponse(kind: frResponse, id: req.id, result: res)
        except ObjectConversionDefect as err:
          var errobj = FastRpcError(code: INVALID_PARAMS, msg: req.procName & " raised an exception")
          if router.stacktraces:
            errobj.trace = err.getStackTraceEntries()
          result = wrapResponseError(req.id, errobj)
        except CatchableError as err:
          # TODO: fix wrapping exception...
          let errobj = FastRpcError(code: SERVER_ERROR, msg: req.procName & " raised an exception")
          if router.stacktraces:
            errobj.trace = err.getStackTraceEntries()
          result = wrapResponseError(req.id, errobj)

proc route*(router: FastRpcRouter,
            req: FastRpcRequest,
            sender: SocketClientSender = emptySender
            ): FastRpcResponse {.gcsafe.} =
  dumpAllocstats:
    if req.kind == frRequest:
      let rpcProc = router.procs.getOrDefault(req.procName)
      result = rpcProc.handleRoute(router, req, sender)
    elif req.kind == frSystemRequest:
      let rpcProc = router.sysprocs.getOrDefault(req.procName)
      result = rpcProc.handleRoute(router, req, sender)

# Define RPC Server #

macro rpc*(p: untyped): untyped =
  ## Define a remote procedure call.
  ## Input and return parameters are defined using the ``do`` notation.
  ## For example:
  ## .. code-block:: nim
  ##    myServer.rpc("path") do(param1: int, param2: float) -> string:
  ##      result = $param1 & " " & $param2
  ##    ```
  ## Input parameters are automatically marshalled from json to Nim types,
  ## and output parameters are automatically marshalled to json for transport.
  let
    path = $p[0]
    params = p[3]
    pragmas = p[4]
    body = p[6]

  echo "RPC: path: ", $path
  echo "RPC: params: ", treeRepr p

  result = newStmtList()
  let
    parameters = params
    syspragma = pragmas.findChild(it.strVal == "system")
    # parameters = body.findChild(it.kind == nnkFormalParams)
    # procs are generated from the stripped path
    pathStr = $path
    # strip non alphanumeric
    procNameStr = pathStr.makeProcName
    # public rpc proc
    procName = ident(procNameStr)
    ctxName = ident("context")
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

  let ContextType = if syspragma.isNil: ident "SocketClientSender"
                    else: ident "RpcSystemContext"
  let ReturnType = if parameters.hasReturnType: parameters[0]
                   else: ident "FastRpcParamsBuffer"

  # delegate async proc allows return and setting of result as native type
  result.add quote do:
    `paramTypes`

    proc `procName`(`paramsIdent`: `paramTypeName`,
                    `ctxName`: `ContextType`
                    ): `ReturnType` =
      {.cast(gcsafe).}:
        `paramSetups`
        `procBody`

  result.add quote do:
    proc `doMain`(params: FastRpcParamsBuffer,
                    context: `ContextType`
                    ): FastRpcParamsBuffer {.gcsafe, nimcall.} =
      var obj: `paramTypeName`
      obj.rpcUnpack(params)

      let res = `procName`(obj, context)
      result = res.rpcPack()

  result.add quote do:
    router.register(`path`, `doMain`)

  # when defined(nimDumpRpcs):
    # echo "\n", pathStr, ": ", result.repr
  echo "rpc return:\n", repr result

proc addStandardSyscalls*(router: var FastRpcRouter) =

  proc listall(): JsonNode {.rpc, system.} =
    let rt = context.router
    var names = newSeqOfCap[string](rt.sysprocs.len())
    for name in rt.procs.keys():
      names.add name
    var methods: JsonNode = %* {"methods": names}
    result = methods

template rpc_methods*(name, blk: untyped): untyped =
  proc `name`*(router {.inject.}: var FastRpcRouter  ) =
    blk
    router.addStandardSysCalls()
  proc `name`*(): FastRpcRouter =
    result = newFastRpcRouter()
    `name`(result)
