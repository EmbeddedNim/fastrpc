
import std/net

import std/monotimes
import std/times
import std/deques
import std/md5

import nativesockets
import os
import math
import std/sysrand, std/random


import mcu_utils/logging
import mcu_utils/msgbuffer

import json
import msgpack4nim
import msgpack4nim/msgpack2json

# Splitting up these type definitions since I want to be able to extract this
# stuff later.
type
  Address* = object
    host*: IpAddress
    port*: Port

  MsgId = uint16

  MessageType = enum
    Con, Non, Ack, Rst

  MessageStatus = enum
    InFlight, Delivered, Failed

  Message* = ref object
    address*: Address
    version*: uint8
    id*: MsgId
    mtype*: MessageType
    token*: string
    data*: string
    acked: bool
    nextSend: MonoTime
    attempt: int

  Settings* = object
    maxIncomingReads*: int
    maxUdpPacketSize*: int
    maxInFlight*: int
    maxFailedQueue*: int
    maxBackoff*: int
    baseBackoff*: Duration

  Reactor* = ref object
    id: uint16
    socket: Socket
    failedMessages*: seq[MsgId]
    messages*: seq[Message]
    toSend: seq[Message]
    settings: Settings

  ReactorClient* = ref object
    reactor*: Reactor
    address*: Address

proc messageToBytes(message: Message, buf: var MsgBuffer) =
  let mtype = uint8(ord(message.mtype))

  let ver = message.version shl 6
  let typ = mtype shl 4
  let tkl = uint8(message.token.len())

  let verTypeTkl = ver or typ or tkl
  buf.write(char(verTypeTkl))

  # Adding the id - in big endian form
  buf.writeUint16(message.id)
  buf.write(message.token)

  if message.data != "":
    buf.write(0xFF.char)
    buf.write(message.data)

proc messageFromBytes(buf: MsgBuffer, address: Address): Message =
  result = Message()
  # let verTypeTkl = cast[uint8](buf[idx])
  buf.setPosition(0)
  let verTypeTkl = buf.readUint8()
  result.version = verTypeTkl shr 6
  result.mtype = MessageType((0b00110000 and verTypeTkl) shr 4)
  let tkl = int(0b00001111 and verTypeTkl)

  # Read 2 bytes for the id. These are in little endian so swap them
  # to get the id in network order
  result.id = buf.readUint16()

  result.token = buf.readStr(tkl)

  if buf.readChar().uint8 == 0xFF:
    result.data = buf.readStrRemaining()

  result.address = address

proc send*(reactor: Reactor, message: Message) =
  # Queue a packet for sending. 
  #
  # raises `ResourceExhaustedError` if queue is full
  if reactor.toSend.len >= reactor.settings.maxInFlight:
    raise newException(ResourceExhaustedError, "maximum messages allowed")

  message.nextSend = getMonoTime()
  message.attempt = 1
  reactor.toSend.add(message)

proc ack(message: Message): Message =
  result = Message()
  result.version = 0
  result.id = message.id
  result.mtype = MessageType.Ack
  result.token = message.token
  result.data = getMd5(message.data)[0..4]
  result.address = message.address

proc sendMessages(reactor: Reactor) =
  var nextMessages: seq[Message]
  let ts = getMonoTime()

  for msg in reactor.toSend:
    # If we're not ready to send this mesage just stash it away and continue
    # to the next
    if msg.nextSend > ts:
      nextMessages.add(msg)
      continue

    if msg.attempt >= 5:
      # We've reached the maximum reset attempts so mark the message as
      # failed and move on.
      reactor.failedMessages.add(msg.id)
      continue

    var buf = MsgBuffer.init(reactor.settings.maxUdpPacketSize)
    messageToBytes(msg, buf)
    reactor.socket.sendTo(msg.address.host, msg.address.port, buf.data[0..buf.pos])

    if msg.mtype == MessageType.Con:
      let nextDelay = reactor.settings.baseBackoff * 2 ^ msg.attempt
      let jittered  = rand(cast[int](nextDelay.inMilliseconds()))
      let delay     = min(reactor.settings.maxBackoff, jittered)
      msg.nextSend = ts + initDuration(milliseconds = delay)
      msg.attempt += 1
      nextMessages.add(msg)

  reactor.toSend = nextMessages

proc readMessages(reactor: Reactor) =
  var
    buf = MsgBuffer.init(reactor.settings.maxUdpPacketSize)

  # Try to read 1000 messages from the socket. This should probably be configurable
  # Once we're done reading packets, decode them and attempt to match up any acknowledgements
  # with outstanding sends
  for idx in 0 ..< reactor.settings.maxIncomingReads:
    var
      byteLen: int
      ripaddr: IpAddress
      rport: Port

    try:

      buf.setPosition(0)
      byteLen = recvFrom(
        reactor.socket,
        buf.data, reactor.settings.maxUdpPacketSize,
        ripaddr, rport
      )
      logInfo "socket recv: byteLen:", byteLen
    except OSError as e:
      # logDebug "socket os error: ", $getCurrentExceptionMsg()
      if e.errorCode == EAGAIN:
        continue
      else:
        raise e

    buf.setPosition(0)
    let address = Address(host: ripaddr, port: rport)
    let message = messageFromBytes(buf, address)

    # If this is an ack than match it with any existing sends and move on
    var toDelete: seq[int] = @[]

    # Scan the toSend buffer and record their index if they match the id of the
    # message we just received. Once we're done we can delete each index from the
    # toSend buffer
    case message.mtype
    of MessageType.Ack:
      for i, toSend in reactor.toSend:
        if toSend.id == message.id:
          toDelete.add(i)

    # Discard any rst messages for now.
    of Con:
      reactor.send(message.ack())
      reactor.messages.add(message)

    of Non:
      reactor.messages.add(message)

    of Rst:
      logWarn "udp reset not implemented!"

    for idx in toDelete:
      reactor.toSend.delete(idx)

proc takeMessages*(reactor: Reactor): owned seq[Message] =
  result = reactor.messages
  reactor.messages = @[]

proc tick*(reactor: Reactor) =
  reactor.messages.setLen(0)
  reactor.sendMessages()
  reactor.readMessages()

  # Bound the size of failed messages
  # slice off the front of failedMessages so .add remains fast
  let
    fmMaxCount = reactor.settings.maxFailedQueue
    fmStartClipped = max(0, reactor.failedMessages.len() - fmMaxCount)
  reactor.failedMessages = 
    reactor.failedMessages[fmStartClipped..^1]

proc getNextId*(reactor: Reactor): uint16 =
  reactor.id += 1
  return reactor.id

proc messageStatus*(reactor: Reactor, msgId: MsgId): MessageStatus =
  for m in reactor.toSend:
    if m.id == msgId:
      return MessageStatus.InFlight

  for failed in reactor.failedMessages:
    if failed == msgId:
      return MessageStatus.Failed

  # If we make it to this point we just return a Delivered status since
  # it was either a non-confirmable message or a confirmable message that was already
  # sent and didn't fail
  return MessageStatus.Delivered

proc genToken(): string =
  var token = newString(4)
  let bytes = rand(int32.high).int32
  token.addInt(bytes)

proc sendConfirm*(reactor: Reactor, address: Address, data: string): uint16  {.discardable.} =
  let message     = Message()
  let id          = reactor.getNextId()
  message.mtype   = MessageType.Con
  message.id      = id
  message.token   = genToken()
  message.address = address
  message.data    = data
  reactor.send(message)
  return id

proc sendConfirm*(reactor: Reactor, host: IpAddress, port: Port, data: string): uint16 {.discardable.} =
  let address = Address(host: host, port: port)
  sendConfirm(reactor, address, data)

proc sendNonconfirm*(reactor: Reactor, address: Address, data: string): uint16 {.discardable.} =
  let message     = Message()
  let id          = reactor.getNextId()
  message.mtype   = MessageType.Non
  message.id      = id
  message.token   = genToken()
  message.address = address
  message.data    = data
  reactor.send(message)
  return id

proc sendNonconfirm*(reactor: Reactor, host: IpAddress, port: Port, data: string): uint16 =
  let address = Address(host: host, port: port)
  sendNonconfirm(reactor, address, data)

proc sendConfirm*(client: ReactorClient, data: string): uint16 {.discardable.} =
  logInfo "send confirm to: ", client.address
  client.reactor.sendConfirm(client.address, data)

proc sendNonconfirm*(client: ReactorClient, data: string): uint16 {.discardable.} =
  client.reactor.sendNonconfirm(client.address, data)

proc cleanupReactor*(reactor: Reactor) =
  # "cleanup reactor"
  if reactor.isNil == false:
    reactor.socket.close()

proc initSettings*(
        maxIncomingReads = 40,
        maxUdpPacketSize = 1500,
        maxInFlight = 2000, # Arbitrary number of packets in flight that we'll allow
        maxFailedQueue = 15,
        maxBackoff = 5_000,
        retryDuration = initDuration(milliseconds = 250)
      ): Settings =

  result = Settings(
    maxIncomingReads: maxIncomingReads,
    maxUdpPacketSize: maxUdpPacketSize,
    maxInFlight: maxInFlight,
    maxFailedQueue: maxFailedQueue,
    maxBackoff: maxBackoff,
    baseBackoff: retryDuration,
  )

proc initReactor*(address: Address, settings = initSettings()): Reactor =
  new(result, cleanupReactor)
  result.id = 1
  result.socket = newSocket(
    Domain.AF_INET,
    nativesockets.SOCK_DGRAM,
    nativesockets.IPPROTO_UDP,
    buffered = false
  )
  result.socket.getFd().setBlocking(false)
  logInfo("Reactor: bind socket:", "host:", address.host, "port:", address.port)
  result.socket.bindAddr(address.port, $address.host)
  result.settings = settings

  logInfo "Reactor: bound socket:" 
  randomize()
  logInfo "random" 

proc initReactor*(host: IpAddress, port: Port, settings = initSettings()): Reactor =
  result = initReactor(Address(host: host, port: port), settings)

proc createClient*(reactor: Reactor, address: Address): ReactorClient =
  new(result)
  result.reactor = reactor
  result.address = address

# Putting this here for now since its not attached to the underlying transport
# layer and I want to keep this isolated.
type
  RPC = tuple
    m: string
    params: seq[string]

let defaultServer = Address(host: IPv4_Any(), port: Port 6310)

const LogNth = 100

proc runTestServer*(remote: Address, server = defaultServer) =
  var
    i = 0
    sendNewMessage = true
    currentRPC: uint16 = 0

  logDebug "Starting reactor", "server(me):", server, "remoteIp:", remote
  let reactor = initReactor(server)

  while true:
    reactor.tick()

    # if i mod LogNth == 0:
    #   logInfo "send telemetry:", "client:", remote

    # let telemetry = pack(123)
    # discard reactor.nonconfirm(remote, telemetry)

    if sendNewMessage:
      logInfo "\n"
      logInfo "Sending RPC"
      sendNewMessage = false

      let rpc: RPC = ("yo", @[$getMonoTime()])
      let bin = pack(rpc)
      currentRPC = reactor.sendConfirm(remote, bin)
      logInfo "RPC ID ", currentRPC

    case reactor.messageStatus(currentRPC):
      of MessageStatus.Delivered:
        logDebug "RPC Success ", currentRPC
        currentRPC = 0
        sendNewMessage = true
      of MessageStatus.Failed:
        logDebug "RPC Failed ", currentRPC
        currentRPC = 0
        sendNewMessage = true
      of MessageStatus.InFlight:
        discard

    for msg in reactor.takeMessages():
      logInfo "Got a new message:", "id:", msg.id, "len:", msg.data.len(), "mtype:", msg.mtype

      # var s = MsgStream.init(msg.data)
      # var rpc = s.toJsonNode()
      # logInfo "RPC: ", $rpc

      # var buf = pack(123)
      # let ack = msg.ack(buf)
      # reactor.send(ack)

    i.inc()
    if i mod LogNth == 0:
      logWarn "reactor tick: ", i
      logWarn "failedMessages:", reactor.failedMessages
      logWarn "messages: ", reactor.messages.len()
      logWarn "toSend: ", reactor.toSend.len()
    # if i > 1_000_000: quit(1)
    when defined(linux):
      sleep(20)

proc runTestClient*(remote: Address, server = defaultServer) =
  var
    i = 0

  logInfo "Starting reactor", "serverIp(me):", server, "remoteIp:", remote
  let reactor = initReactor(server)

  logInfo "reactor running "

  while true:
    reactor.tick()

    # logInfo "send telemetry:", "client:", remote 
    # let telemetry = pack(123)
    # discard reactor.nonconfirm(remote, telemetry)

    for msg in reactor.takeMessages():
      logInfo "Got a new message:", "id:", msg.id, "len:", msg.data.len(), "mtype:", msg.mtype

      var s = MsgStream.init(msg.data)
      s.setPosition(0)

      var rpc = s.toJsonNode()
      logInfo "RPC: repr data:", repr msg.data
      logInfo "RPC:", $rpc

      var buf = pack(123)
      let ack = msg.ack()
      reactor.send(ack)

    if i mod LogNth == 0:
      logWarn "reactor tick: ", i

    i.inc()
    sleep(20)


when isMainModule:
  const serverIp {.strdefine.} = "0.0.0.0"
  const serverPort {.intdefine.} = 6310
  const remoteIp {.strdefine.} = "127.0.0.1"
  const remotePort {.intdefine.} = 6310

  let
    server = Address(host: parseIpAddress serverIp, port: Port serverPort)
    remote = Address(host: parseIpAddress remoteIp, port: Port remotePort)

  when defined(UdpServer):
    runTestServer(remote, server=server)
  elif defined(UdpClient):
    runTestClient(remote, server=server)
  else:
    {.fatal: "use -d:UdpServer or -d:UdpClient".}
