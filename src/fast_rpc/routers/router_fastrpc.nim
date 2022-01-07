import tables, strutils, macros, os

import mcu_utils/basictypes
import mcu_utils/msgbuffer
import mcu_utils/logging

import msgpack4nim
export msgpack4nim

import msgpack4nim/msgpack2json

import protocol_frpc
export protocol_frpc
export Millis

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
  ## Create local variables for each parameter in the inner RPC call proc
  if params.isNil: return

  result = newStmtList()
  var varList = newSeq[NimNode]()
  for paramid, paramType in paramsIter(params):
    varList.add quote do:
      var `paramid`: `paramType` = `paramsIdent`.`paramid`
  result.add varList
  # echo "paramsSetup return:\n", treeRepr result

proc mkParamsType*(paramsIdent, paramsType, params: NimNode): NimNode =
  ## Create a type that represents the arguments for this rpc call
  ## 
  ## Example: 
  ## 
  ##   proc multiplyrpc(a, b: int): int {.rpc.} =
  ##     result = a * b
  ## 
  ## Becomes:
  ##   proc multiplyrpc(params: RpcType_multiplyrpc): int = 
  ##     var a = params.a
  ##     var b = params.b
  ##   
  ##   proc multiplyrpc(params: RpcType_multiplyrpc): int = 
  ## 
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

proc rpcReply*[T](context: RpcContext, value: T, kind: FastRpcType): bool =
  ## TODO: FIXME
  ## this turned out kind of ugly... 
  ## but it works, think it'll work for subscriptions too 
  var packed: FastRpcParamsBuffer = rpcPack(value)
  let res: FastRpcResponse = wrapResponse(context.id, packed, kind)
  var so = MsgBuffer.init(res.result.buf.data.len() + sizeof(res))
  so.pack(res)
  return context.sender(so.data)

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

proc emptySender(data: string): bool = false

proc handleRoute*(
            rpcProc: FastRpcProc,
            router: FastRpcRouter,
            stacktraces: bool,
            req: FastRpcRequest,
            sender: SocketClientSender = emptySender
            ): FastRpcResponse {.gcsafe.} =

      if rpcProc.isNil:
        let msg = req.procName & " is not a registered RPC method."
        let err = FastRpcError(code: METHOD_NOT_FOUND, msg: msg)
        result = wrapResponseError(req.id, err)
      else:
        try:
          # Handle rpc request the `context` variable is different
          # based on whether the rpc request is a system/regular/subscription
          var ctx = RpcContext(id: req.id, sender: sender, router: router)
          let res: FastRpcParamsBuffer = rpcProc(req.params, ctx)
          result = FastRpcResponse(kind: frResponse, id: req.id, result: res)
        except ObjectConversionDefect as err:
          result = wrapResponseError(
                      req.id,
                      INVALID_PARAMS,
                      req.procName & " raised an exception",
                      err, 
                      stacktraces)
        except CatchableError as err:
          result = wrapResponseError(
                      req.id,
                      INTERNAL_ERROR,
                      req.procName & " raised an exception",
                      err, 
                      stacktraces)

proc route*(router: FastRpcRouter,
            req: FastRpcRequest,
            sender: SocketClientSender = emptySender
            ): FastRpcResponse {.gcsafe.} =
  ## Route's an rpc request. 
  # dumpAllocstats:
    if req.kind == frRequest:
      let rpcProc = router.procs.getOrDefault(req.procName)
      result = rpcProc.handleRoute(router, router.stacktraces, req, sender)
    elif req.kind == frSystemRequest:
      let rpcProc = router.sysprocs.getOrDefault(req.procName)
      result = rpcProc.handleRoute(router, router.stacktraces, req, sender)
    elif req.kind == frSubscribe:
      let rpcProc = router.procs.getOrDefault(req.procName)
      result = rpcProc.handleRoute(router, router.stacktraces, req, sender)
    else:
      result = wrapResponseError(
                  req.id,
                  SERVER_ERROR,
                  "unimplemented request typed",
                  nil, 
                  router.stacktraces)

proc threadRunner(args: FastRpcThreadArg) =
  try:
    os.sleep(1)
    let fn = args[0]
    var val = fn(args[1], args[2])
    discard rpcReply(args[2], val, frPublishDone)
  except InetClientDisconnected:
    logWarn("client disconnected for subscription")
    discard


# ========================= Define RPC Server ========================= #
template mkSubscriptionMethod(rpcfunc: FastRpcProc): FastRpcProc = 

  when compiles(typeof Thread):
    proc rpcPublishThread(params: FastRpcParamsBuffer, context: RpcContext): FastRpcParamsBuffer {.gcsafe, nimcall.} =
      echo "rpcPublishThread: ", repr params
      let subid = randBinString()
      context.id = subid
      context.router.threads[subid] = Thread[FastRpcThreadArg]()
      let args: (FastRpcProc, FastRpcParamsBuffer, RpcContext) = (rpcfunc, params, context)
      createThread(context.router.threads[subid], threadRunner, args)
      result = rpcPack(("subscription", subid,))

    rpcPublishThread
  else:
    error("must have threads enabled")
  


macro rpcImpl*(p: untyped, publish: untyped): untyped =
  ## Define a remote procedure call.
  ## Input and return parameters are defined using proc's with the `rpc` 
  ## pragma. 
  ## 
  ## For example:
  ## .. code-block:: nim
  ##    proc methodname(param1: int, param2: float): string {.rpc.} =
  ##      result = $param1 & " " & $param2
  ##    ```
  ## 
  ## Input parameters are automatically marshalled from fast rpc binary 
  ## format (msgpack) and output parameters are automatically marshalled
  ## back to the fast rpc binary format (msgpack) for transport.
  
  if publish.kind != nnkNilLit:
    echo "RPC: pub: tp: ", typeof publish
    echo "RPC: pub: kd: ", publish.kind
    echo "RPC: pub: ", repr publish
    echo "RPC: ", p.treeRepr
    
  let
    path = $p[0]
    params = p[3]
    pragmas = p[4]
    body = p[6]

  result = newStmtList()
  let
    parameters = params
    # determine if this is a "system" rpc method
    pubthread = publish.kind == nnkStrLit and publish.strVal == "thread"
    pubtask = publish.kind == nnkInt64Lit 
    syspragma = not pragmas.findChild(it.repr == "system").isNil

    # rpc method names
    pathStr = $path
    procNameStr = pathStr.makeProcName()

    # public rpc proc
    procName = ident(procNameStr)
    ctxName = ident("context")

    # parameter type name
    paramsIdent = genSym(nskParam, "args")
    paramTypeName = ident("RpcType_" & procNameStr)

    rpcMethod = ident(procNameStr & "RpcMethod")
    rpcSubscribeMethod = ident(procNameStr & "RpcSubscribe")

  var
    # process the argument types
    paramSetups = mkParamsVars(paramsIdent, paramTypeName, parameters)
    paramTypes = mkParamsType(paramsIdent, paramTypeName, parameters)
    procBody = if body.kind == nnkStmtList: body else: body.body

  # set the "context" variable type and the return types
  # echo "PUBTHEAD: ", pubthread 

  # let ContextType = if syspragma.isNil: ident "RpcContext"
                    # else: ident "RpcSystemContext"

  let ContextType = ident "RpcContext"
  let ReturnType = if parameters.hasReturnType:
                      parameters[0]
                   else:
                      error("must provide return type")
                      ident "void"

  # Create the proc's that hold the users code 
  result.add quote do:
    `paramTypes`

    proc `procName`(`paramsIdent`: `paramTypeName`,
                    `ctxName`: `ContextType`
                    ): `ReturnType` =
      {.cast(gcsafe).}:
        `paramSetups`
        `procBody`

  # Create the rpc wrapper procs
  result.add quote do:
    proc `rpcMethod`(params: FastRpcParamsBuffer, context: `ContextType`): FastRpcParamsBuffer {.gcsafe, nimcall.} =
      var obj: `paramTypeName`
      obj.rpcUnpack(params)

      let res = `procName`(obj, context)
      result = res.rpcPack()

  # Register rpc wrapper
  if pubthread:
    result.add quote do:
      let subm: FastRpcProc = mkSubscriptionMethod(`rpcMethod`)
      router.register(`path`, subm)
  elif syspragma:
    result.add quote do:
      router.sysRegister(`path`, `rpcMethod`)
  else:
    result.add quote do:
      router.register(`path`, `rpcMethod`)

template rpc*(p: untyped): untyped =
  rpcImpl(p, nil)

template rpcPublisher*(args: static[Millis], p: untyped): untyped =
  static:
    echo "RPC: PUBLISHER TICK"
  rpcImpl(p, args)

template rpcPublisherThread*(p: untyped): untyped =
  static:
    echo "RPC: PUBLISHER THREAD"
  rpcImpl(p, "thread")

proc addStandardSyscalls*(router: var FastRpcRouter) =

  proc listall(): JsonNode {.rpc, system.} =
    let names = context.router.listMethods()
    let sysnames = context.router.listSysMethods()
    result = %* {"methods": names, "system": sysnames}

template rpc_methods*(name, blk: untyped): untyped =
  ## Define a proc called `name` that creates returns an RPC
  ## router. The router will contain all the proc's in given
  ## contained in the passed in code block that are
  ## tagged with the `rpc` pragma. 
  ## 
  ## For example:
  ## .. code-block:: nim
  ##    rpc_methods(myRpcExample):
  ##      proc add(a: int, b: int): int {.rpc, system.} =
  ##        result = 1 + a + b
  ##      proc addAll(vals: seq[int]): int {.rpc.} =
  ##        for val in vals:
  ##          result = result + val
  ## 
  ##    when isMainModule:
  ##      let inetAddrs = [
  ##        newInetAddr("0.0.0.0", 5656, Protocol.IPPROTO_TCP),
  ##      ]
  #   
  ##      var router = myRpcExample()
  ##      for rpc in router.procs.keys():
  ##        echo "  rpc: ", rpc
  ##      startSocketServer(inetAddrs, newFastRpcServer(router, prefixMsgSize=true))
  ##    ```
  ## 
  proc `name`*(router {.inject.}: var FastRpcRouter  ) =
    blk
    router.addStandardSysCalls()
  proc `name`*(): FastRpcRouter =
    result = newFastRpcRouter()
    `name`(result)

template rpcReply*(value: untyped): untyped =
  rpcReply(context, value, frPublish)

template rpcPublish*(arg: untyped): untyped =
  rpcReply(context, arg, frPublish)