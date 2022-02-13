import tables, strutils, macros
import options

import mcu_utils/basictypes
import mcu_utils/msgbuffer
include mcu_utils/threads

export options
import datatypes
export datatypes
import router
export router

proc makeProcName(s: string): string =
  result = ""
  for c in s:
    if c.isAlphaNumeric: result.add c

proc hasReturnType(params: NimNode): bool =
  if params != nil and params.len > 0 and params[0] != nil and
     params[0].kind != nnkEmpty:
    result = true

proc firstArgument(params: NimNode): (string, string) =
  if params != nil and
      params.len > 0 and
      params[1] != nil and
      params[1].kind == nnkIdentDefs:
    result = (params[1][0].strVal, params[1][1].repr)
  else:
    result = ("", "")

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

macro rpcImpl*(p: untyped, publish: untyped, qarg: untyped): untyped =
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
  
  let
    path = $p[0]
    params = p[3]
    pragmas = p[4]
    body = p[6]

  result = newStmtList()
  var
    parameters = params

  let
    # determine if this is a "system" rpc method
    pubthread = publish.kind == nnkStrLit and publish.strVal == "thread"
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

  var
    # process the argument types
    paramSetups = mkParamsVars(paramsIdent, paramTypeName, parameters)
    paramTypes = mkParamsType(paramsIdent, paramTypeName, parameters)
    procBody = if body.kind == nnkStmtList: body else: body.body

  let ContextType = ident "RpcContext"
  let ReturnType = if parameters.hasReturnType:
                      parameters[0]
                   else:
                      error("must provide return type")
                      ident "void"

  # Create the proc's that hold the users code 
  if not pubthread:
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

    if syspragma:
      result.add quote do:
        sysRegister(router, `path`, `rpcMethod`)
    else:
      result.add quote do:
        register(router, `path`, `rpcMethod`)

  elif pubthread:
    result.add quote do:
      var `rpcMethod`: FastRpcEventProc
      template `procName`(): `ReturnType` =
        `procBody`
      closureScope: # 
        `rpcMethod` =

          proc(): FastRpcParamsBuffer =
            let res = `procName`()
            result = rpcPack(res)

      register(router, `path`, `qarg`.evt, `rpcMethod`)

macro rpcOption*(p: untyped): untyped =
  result = p

macro rpcSetter*(p: untyped): untyped =
  result = p
macro rpcGetter*(p: untyped): untyped =
  result = p

template rpc*(p: untyped): untyped =
  rpcImpl(p, nil, nil)

template rpcPublisher*(args: static[Millis], p: untyped): untyped =
  rpcImpl(p, args, nil)

template rpcThread*(p: untyped): untyped =
  `p`

macro rpcSerializer*(p: untyped): untyped =
  # rpcImpl(p, "thread", qarg)
  result = p

macro DefineRpcs*(name: untyped, args: varargs[untyped]) =
  ## annotates that a proc is an `rpcRegistrationProc` and
  ## that it takes the correct arguments. In particular 
  ## the first parameter must be `router: var FastRpcRouter`. 
  ## 
  let
    params = if args.len() >= 2: args[0..^2]
             else: newSeq[NimNode]()
    pbody = args[^1]

  # if router.repr != "var FastRpcRouter":
  #   error("Incorrect definition for a `rpcNamespace`." &
  #   "The first parameter to an rpc registration namespace must be named `router` and be of type `var FastRpcRouter`." &
  #   " Instead got: `" & treeRepr(router) & "`")
  let rname = ident("router")
  result = quote do:
    proc `name`(`rname`: var FastRpcRouter) =
      `pbody`
  
  var pArgs = result[3]
  for param in params:
    let parg = newIdentDefs(param[0], param[1])
    pArgs.add parg
  echo "PARGS: ", pArgs.treeRepr

type
  RpcOption*[T] = object
    data*: T
    ch*: Chan[T]

macro DefineRpcOptions*[T](name: untyped, args: varargs[untyped]) =
  ## annotates that a proc is an `rpcRegistrationProc` and
  ## that it takes the correct arguments. In particular 
  ## the first parameter must be `router: var FastRpcRouter`. 
  ## 
  let
    params = if args.len() >= 1: args[0..^2]
             else: newSeq[NimNode]()
    pbody = args[^1]

  let rname = ident("router")
  result = quote do:
    proc `name`(`rname`: var FastRpcRouter) =
      `pbody`
  
  var pArgs = result[3]
  for param in params:
    let parg = newIdentDefs(param[0], param[1])
    pArgs.add parg
  echo "PARGS: ", pArgs.treeRepr

macro registerRpcs*(router: var FastRpcRouter, namespace: typed, args: varargs[untyped]) =
  echo "registerNamespace:name: ", treeRepr namespace
  echo "registerNamespace:ARGS: ", treeRepr args
  if args.len() > 0:
    result = quote do:
      `namespace`(router, `args`)
  else:
    result = quote do:
      `namespace`(router)
  echo "registerNamespace:RES: ", treeRepr result

macro registerDatastream*(router: var FastRpcRouter,
                          namespace: typed,
                          args: varargs[untyped]) =
  echo "registerNamespace:name: ", treeRepr namespace
  echo "registerNamespace:ARGS: ", treeRepr args
  if args.len() > 0:
    result = quote do:
      `namespace`(router, `args`)
  else:
    result = quote do:
      `namespace`(router)
  echo "registerNamespace:RES: ", treeRepr result

proc getUpdatedOption*[T](chan: RpcOption[T]): Option[T] =
  # chan.tryRecv()
  return some(T())
proc getRpcOption*[T](chan: RpcOption[T]): T =
  # chan.tryRecv()
  return T()


proc rpcReply*[T](context: RpcContext, value: T, kind: FastRpcType): bool =
  ## TODO: FIXME
  ## this turned out kind of ugly... 
  ## but it works, think it'll work for subscriptions too 
  var packed: FastRpcParamsBuffer = rpcPack(value)
  let res: FastRpcResponse = wrapResponse(context.id, packed, kind)
  var so = MsgBuffer.init(res.result.buf.data.len() + sizeof(res))
  so.pack(res)
  # return context.send(so.data)

template rpcReply*(value: untyped): untyped =
  rpcReply(context, value, Publish)

template rpcPublish*(arg: untyped): untyped =
  rpcReply(context, arg, Publish)