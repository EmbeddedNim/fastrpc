import json, tables, strutils, macros, options
import strformat
import net, os
import streams
import times
import stats
import sequtils
import locks
import sugar
import terminal 
import colors

import cligen
from cligen/argcvt import ArgcvtParams, argKeys         # Little helpers

import msgpack4nim
import msgpack4nim/msgpack2json
import fast_rpc/socketserver/common_handlers
import fast_rpc/routers/protocol_frpc

enableTrueColors()
proc print*(text: varargs[string]) =
  stdout.write(text)
  stdout.write("\n")
  stdout.flushFile()

proc print*(color: Color, text: varargs[string]) =
  stdout.setForegroundColor(color)

  stdout.write text
  stdout.write "\n"
  # stdout.write "\e[0m\n"
  stdout.setForegroundColor(fgDefault)
  stdout.flushFile()


type 
  RpcOptions = object
    id: int
    showstats: bool
    keepalive: bool
    count: int
    delay: int
    jsonArg: string
    ipAddr: IpAddress
    port: Port
    prettyPrint: bool
    quiet: bool
    dryRun: bool
    noprint: bool

var totalTime = 0'i64
var totalCalls = 0'i64

template timeBlock(n: string, opts: RpcOptions, blk: untyped): untyped =
  let t0 = getTime()
  blk

  let td = getTime() - t0
  if not opts.noprint:
    print colGray, "[took: ", $(td.inMicroseconds().float() / 1e3), " millis]"
  totalCalls.inc()
  totalTime = totalTime + td.inMicroseconds()
  allTimes.add(td.inMicroseconds())
  


var
  id: int = 1
  allTimes = newSeq[int64]()

proc execRpc( client: Socket, i: int, call: var FastRpcRequest, opts: RpcOptions): JsonNode = 
  {.cast(gcsafe).}:
    call.id = id
    inc(id)

    var ss = MsgBuffer.init()
    ss.pack(call)
    let mcall = ss.data

    timeBlock("call", opts):
      client.send( mcall )
      var msgLenBytes = client.recv(4, timeout = -1)
      if msgLenBytes.len() == 0: return
      var msgLen: int32 = msgLenBytes.lengthFromBigendian32()
      print("[socket data:lenstr: " & repr(msgLenBytes) & "]")
      print("[socket data:len: " & repr(msgLen) & "]")

      var msg = ""
      while msg.len() < msgLen:
        print("[reading msg]")
        let mb = client.recv(4096, timeout = -1)
        if not opts.quiet and not opts.noprint:
          print("[read bytes: " & $mb.len() & "]")
        msg.add mb

    if not opts.quiet and not opts.noprint:
      print("[socket data: " & repr(msg) & "]")

    if not opts.quiet and not opts.noprint:
      print colGray, "[read bytes: ", $msg.len(), "]"
      print colGray, "[read: ", repr(msg), "]"

    var mnode: JsonNode = msg.toJsonNode()

    if not opts.noprint:
      print("")

    if not opts.noprint: 
      if opts.prettyPrint:
        print(colAquamarine, pretty(mnode))
      else:
        print(colAquamarine, $(mnode))

    if not opts.quiet and not opts.noprint:
      print colGreen, "[rpc done at " & $now() & "]"

    if opts.delay > 0:
      os.sleep(opts.delay)

    mnode

proc runRpc(opts: RpcOptions, req: FastRpcRequest) = 
  {.cast(gcsafe).}:
    # for (f,v) in margs.pairs():
      # call[f] = v
    var call = req

    let domain = if opts.ipAddr.family == IpAddressFamily.IPv6: Domain.AF_INET6 else: Domain.AF_INET6 
    let client: Socket = newSocket(buffered=false, domain=domain)

    print(colYellow, "[connecting to server ip addr: ", repr opts.ipAddr,"]")
    client.connect($opts.ipAddr, opts.port)
    print(colYellow, "[connected to server ip addr: ", $opts.ipAddr,"]")
    print(colBlue, "[call: ", repr call, "]")

    for i in 1..opts.count:
      try:
        discard client.execRpc(i, call, opts)
      except Exception:
        print(colRed, "[exception: ", getCurrentExceptionMsg() ,"]")

    while opts.keepalive:
      let mb = client.recv(4096, timeout = -1)
      if mb != "":
        try:
          let res = mb.toJsonNode()
          print("subscription: ", $res)
        except Exception:
          print(colRed, "[exception: ", getCurrentExceptionMsg() ,"]")
    client.close()

    print("\n")

    if opts.showstats: 
      print(colMagenta, "[total time: " & $(totalTime.float() / 1e3) & " millis]")
      print(colMagenta, "[total count: " & $(totalCalls) & " No]")
      print(colMagenta, "[avg time: " & $(float(totalTime.float()/1e3)/(1.0 * float(totalCalls))) & " millis]")

      var ss: RunningStat ## Must be "var"
      ss.push(allTimes.mapIt(float(it)/1000.0))

      print(colMagenta, "[mean time: " & $(ss.mean()) & " millis]")
      print(colMagenta, "[max time: " & $(allTimes.max().float()/1_000.0) & " millis]")
      print(colMagenta, "[variance time: " & $(ss.variance()) & " millis]")
      print(colMagenta, "[standardDeviation time: " & $(ss.standardDeviation()) & " millis]")

proc call(ip: IpAddress,
          cmdargs: seq[string],
          port=Port(5555),
          dry_run=false,
          quiet=false,
          pretty=false,
          count=1,
          delay=0,
          showstats=false,
          keepalive=false,
          rawJsonArgs="") =

  var opts = RpcOptions(count: count,
                        delay: delay,
                        ipAddr: ip,
                        port: port,
                        quiet: quiet,
                        dryRun: dry_run,
                        showstats: showstats,
                        prettyPrint: pretty,
                        keepalive: keepalive)

  ## Some API call
  let
    name = cmdargs[0]
    args = cmdargs[1..^1]
    # cmdargs = @[name, rawJsonArgs]
    pargs = collect(newSeq):
      for ca in args:
        parseJson(ca)
    jargs = if rawJsonArgs == "": %pargs else: rawJsonArgs.parseJson() 
  
  echo fmt("rpc call: name: '{name}' args: '{args}' ip:{repr ip} ")
  echo fmt("rpc params:pargs: {repr pargs}")
  echo fmt("rpc params:jargs: {repr jargs}")
  echo fmt("rpc params: {$jargs}")

  let margs = %* {"method": name, "params": % jargs }

  var ss = MsgBuffer.init()
  ss.write jargs.fromJsonNode()
  # ss.pack(jargs)
  var call = FastRpcRequest(kind: frRequest,
                            id: 1,
                            procName: name,
                            params: (buf: ss))

  print(colYellow, "CALL:", repr call)
  var sc = MsgBuffer.init()
  sc.pack(call)
  let mcall = sc.data
  print(colYellow, "MCALL:", repr mcall)

  if not opts.dryRun:
    opts.runRpc(call)

proc run_cli*() =
  proc argParse(dst: var IpAddress, dfl: IpAddress, a: var ArgcvtParams): bool =
    try:
      dst = a.val.parseIpAddress()
    except CatchableError:
      return false
    return true

  proc argHelp(dfl: IpAddress; a: var ArgcvtParams): seq[string] =
    argHelp($(dfl), a)

  proc argParse(dst: var Port, dfl: Port, a: var ArgcvtParams): bool =
    try:
      dst = Port(a.val.parseInt())
    except CatchableError:
      return false
    return true
  proc argHelp(dfl: Port; a: var ArgcvtParams): seq[string] =
    argHelp($(dfl), a)

  dispatchMulti([call])

when isMainModule:
  run_cli()