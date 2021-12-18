import std/sysrand

import router_json

type
  JsonRpcSubThreadTable* = TableRef[JsonRpcSubId, Thread[JsonRpcSubsArgs]]

proc newJsonRpcSubsId*(): JsonRpcSubId =
  var subid: JsonRpcSubId
  if urandom(subid.uuid):
    subid.okay = true
  return subid

proc subscribeWithThread*(subs: var JsonRpcSubThreadTable,
                            sender: SocketClientSender,
                            subsfunc: proc (args: JsonRpcSubsArgs) {.gcsafe, nimcall.},
                            data: sink JsonNode = % nil
                           ): JsonRpcSubId =
  var subid = newJsonRpcSubsId()
  subs[subid] = Thread[JsonRpcSubsArgs]()
  var args = JsonRpcSubsArgs(subid: subid, data: data, sender: sender)
  createThread(subs[subid], subsfunc, args)

  result = subid
