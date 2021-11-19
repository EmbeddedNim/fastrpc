
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

import msgpack4nim/msgpack2json

import cligen
from cligen/argcvt import ArgcvtParams, argKeys         # Little helpers

import ../udpsocket

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

proc execRpc(client: ReactorClient, i: int, call: JsonNode, opts: RpcOptions): JsonNode = 
  {.cast(gcsafe).}:
    call["id"] = %* id
    inc(id)

    let mcall = call.fromJsonNode()

    timeBlock("call", opts):
      client.sendConfirm(mcall)
      print colGray, "wait for response..."

      var msg = ""
      var waitingForResponse = true
      while waitingForResponse:
        client.reactor.tick()
        for umsg in client.reactor.takeMessages():
          print colGray, "Got a new message:", "id:", $umsg.id, "len:", $umsg.data.len(), "mtype:", $umsg.mtype
          msg = umsg.data
          waitingForResponse = false

    if not opts.quiet and not opts.noprint:
      print("[udp data: " & repr(msg) & "]")

    if not opts.quiet and not opts.noprint:
      print colGray, "[read bytes: ", $msg.len(), "]"
      print colGray, "[read: ", repr(msg), "]"

    var mnode: JsonNode = 
        msg.toJsonNode()

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

proc initRpcCall(id=1): JsonNode =
  result = %* { "jsonrpc": "2.0", "id": id}
proc initRpcCall(name: string, args: JsonNode, id=1): JsonNode =
  result = %* { "jsonrpc": "2.0", "id": id, "method": name, "params": args}

proc runRpc(opts: RpcOptions, margs: JsonNode) = 
  {.cast(gcsafe).}:
    var call = initRpcCall()

    for (f,v) in margs.pairs():
      call[f] = v

    let settings = initSettings()
    let server = Address(host: IPv4_any(), port: Port 6310)
    let clientAddr = Address(host: opts.ipAddr, port: opts.port)

    let reactor: Reactor = initReactor(server, settings)
    let client: ReactorClient = reactor.createClient(clientAddr)

    print(colBlue, "[call: ", $call, "]")

    for i in 1..opts.count:
      discard client.execRpc(i, call, opts)

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

proc call(ip: IpAddress, cmdargs: seq[string], port=Port(6310), dry_run=false, quiet=false, pretty=false, count=1, delay=0, rawJsonArgs="") =
  var opts = RpcOptions(count: count, delay: delay, ipAddr: ip, port: port, quiet: quiet, dryRun: dry_run, prettyPrint: pretty)

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
  echo fmt("rpc params: {repr jargs}")
  echo fmt("rpc params: {$jargs}")

  let margs = %* {"method": name, "params": % jargs }
  if not opts.dryRun:
    opts.runRpc(margs)

import progress


# runRpc()

when isMainModule:
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

  dispatchMulti([call],)
