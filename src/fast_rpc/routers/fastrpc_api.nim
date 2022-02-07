import tables, strutils, macros, os

import mcu_utils/basictypes
import mcu_utils/msgbuffer
import mcu_utils/logging
include mcu_utils/threads

import msgpack4nim
export msgpack4nim

import msgpack4nim/msgpack2json

export Millis

import protocol_frpc
export protocol_frpc

import router_fastrpc
export router_fastrpc

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

proc mkParamsVars(paramsIdent, paramsType, params: NimNode): NimNode =
  ## Create local variables for each parameter in the actual RPC call proc
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
      let subFunc: FastRpcProc = mkSubscriptionMethod(procName, `rpcMethod`)
      let subm: FastRpcProc = mkSubscriptionMethod(procName, `rpcMethod`)
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

template rpcRegisterMethodsProc*(name, blk: untyped): untyped =
  ## Template to generate a proc called `procName`. This proc
  ## configures and returns an RPC router.
  ## 
  ## The returned RPC router will have all the proc's
  ## registered from the passed in code block that are
  ## tagged with the `rpc` pragma. 
  ## 
  ## For example:
  ## .. code-block:: nim
  ##    rpcRegisterMethodsProc(name=initMyExampleRouter):
  ## 
  ##      proc add(a: int, b: int): int {.rpc, system.} =
  ##        result = 1 + a + b
  ## 
  ##      proc addAll(vals: seq[int]): int {.rpc.} =
  ##        for val in vals:
  ##          result = result + val
  ## 
  ##    # Create a new router using our proc generated above:
  ##    var router = initMyExampleRouter()
  ## 
  ##    # This will list out `add` and `addAll`:
  ##    for rpc in router.procs.keys():
  ##      echo "  rpc: ", rpc
  ## 
  ##    # Start a socker server
  ##    let inetAddrs = [newInetAddr("0.0.0.0", 5656, Protocol.IPPROTO_TCP), ]
  ##    startSocketServer(inetAddrs, newFastRpcServer(router, prefixMsgSize=true))
  ##    ```
  ## 
  ## An alternative usage is to pass an existing router 
  ## as an argument. The RPC methods will be registerd 
  ## on this passed in router instead.
  ## 
  ## Example usage of appending RPC methods to a router:
  ## .. code-block:: nim
  ##    # Create some new RPC Router
  ##    var router = mainRpcRouterExample()
  ## 
  ##    # call our previous init router proc to register methods 
  ##    router.initMyExampleRouter()
  ## 
  ##    # This will print out all methods from
  ##    # `mainRpcRouterExample` and `initMyExampleRouter`
  ##    for rpc in router.procs.keys():
  ##      echo "  rpc: ", rperror
  ## 
  ##    # Start a socker server
  ##    let inetAddrs = [newInetAddr("0.0.0.0", 5656, Protocol.IPPROTO_TCP), ]
  ##    startSocketServer(inetAddrs, newFastRpcServer(router, prefixMsgSize=true))
  ##    ```
  
  proc `name`*(router {.inject.}: var FastRpcRouter  ) =
    ## Proc that registers all the methods in the `blk`
    blk
    router.addStandardSysCalls()

  proc `name`*(): FastRpcRouter =
    ## convenience function to create a new router and init it
    result = newFastRpcRouter()
    `name`(result)

template rpc_methods*(procName, blk: untyped): untyped {.
    deprecated: "use `rpcRegisterMethodsProc` instead".} =
  rpcRegisterMethodsProc(procName, blk)

proc rpcReply*[T](context: RpcContext, value: T, kind: FastRpcType): bool =
  ## TODO: FIXME
  ## this turned out kind of ugly... 
  ## but it works, think it'll work for subscriptions too 
  var packed: FastRpcParamsBuffer = rpcPack(value)
  let res: FastRpcResponse = wrapResponse(context.id, packed, kind)
  var so = MsgBuffer.init(res.result.buf.data.len() + sizeof(res))
  so.pack(res)
  return context.sender(so.data)

template rpcReply*(value: untyped): untyped =
  rpcReply(context, value, frPublish)

template rpcPublish*(arg: untyped): untyped =
  rpcReply(context, arg, frPublish)