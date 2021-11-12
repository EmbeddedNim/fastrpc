
# TODO - These imports probably don't work on zephyr so we should fix that
import system
import std/net
import std/monotimes
import std/times
import nativesockets
import os
import std/sysrand
import std/random
import math

import json
import msgpack4nim
import msgpack4nim/msgpack2json

const
  defaultMaxUdpPacketSize = 1500
  defaultMaxInFlight = 2000 # Arbitrary number of packets in flight that we'll allow
  defaultMaxBackoff = 5_000
  defaultRetryDuration = initDuration(milliseconds = 250)

# Splitting up these type definitions since I want to be able to extract this
# stuff later.
type
  Address* = object
    host*: string
    port*: Port

  MsgId = uint16

  MessageType = enum
    Con, Non, Ack, Rst

  MessageStatus = enum
    InFlight, Delivered, Failed

  Message = ref object
    address*: Address
    version*: uint8
    id*: MsgId
    mtype*: MessageType
    token*: string
    data*: string
    acked: bool
    nextSend: MonoTime
    attempt: int

  DebugInfo = object
    maxUdpPacketSize: int
    maxInFlight: int
    maxBackoff: int
    baseBackoff: Duration

  Reactor = ref object
    id: uint16
    socket: Socket
    failedMessages*: seq[Message]
    messages*: seq[Message]
    toSend: seq[Message]
    debug: DebugInfo

proc initAddress*(host: string, port: Port): Address =
  result.host = host
  result.port = port

proc initAddress*(host: string, port: int): Address =
  result.host = host
  result.port = Port(port)

proc messageToBytes(message: Message, buf: var string) =
  let mtype: uint8 = case message.mtype:
    of MessageType.Con: 0
    of MessageType.Non: 1
    of MessageType.Ack: 2
    of MessageType.Rst: 3

  let ver = message.version shl 6
  let typ = mtype shl 4
  let tkl = cast[uint8](message.token.len)

  let verTypeTkl = ver or typ or tkl
  buf.add(verTypeTkl.char)

  # Adding the id. Cast each byte of the id into 2 and then add them to the buffer
  # in big endian form
  var bytes: array[2, uint8]
  bytes[0] = cast[uint8](message.id shr 8)
  bytes[1] = cast[uint8](message.id and 0xFF)

  for byte in bytes:
    buf.add(byte.char)

  buf.add(message.token)

  if message.data != "":
    buf.add(0xFF.char)
    buf.add(message.data)

proc messageFromBytes(buf: string, address: Address): Message =
  result = Message()
  var idx = 0
  let verTypeTkl = cast[uint8](buf[idx])
  let version = verTypeTkl shr 6
  result.version = version
  result.mtype = case ((0b00110000 and verTypeTkl) shr 4):
    of 0: MessageType.Con
    of 1: MessageType.Non
    of 2: MessageType.Ack
    of 3: MessageType.Rst
    else:
      raise
  let tkl: int = cast[int](0b00001111 and verTypeTkl)
  idx += 1

  # Read 2 bytes for the id. These are in little endian so swap them
  # to get the id in network order
  let id = cast[ptr uint16](buf[idx].unsafeAddr)[]
  let tmp = cast[array[2, uint8]](id)
  result.id = (tmp[0].uint16 shl 8) or tmp[1].uint16
  idx += 2

  result.token = buf[idx ..< idx+tkl]
  idx += tkl

  if cast[int](buf[idx]) == 0xFF:
    result.data = buf[idx+1 ..< buf.len]

  result.address = address

proc sendMessages(reactor: Reactor) =
  var nextMessages: seq[Message]
  let now = getMonoTime()

  for msg in reactor.toSend:
    # If we're not ready to send this mesage just stash it away and continue
    # to the next
    if msg.nextSend > now:
      nextMessages.add(msg)
      continue

    if msg.attempt >= 5:
      # We've reached the maximum reset attempts so mark the message as
      # failed and move on.
      reactor.failedMessages.add(msg)
      continue

    var buf = newStringOfCap(reactor.debug.maxUdpPacketSize)
    messageToBytes(msg, buf)
    reactor.socket.sendTo(msg.address.host, msg.address.port, buf)

    if msg.mtype == MessageType.Con:
      let nextDelay = reactor.debug.baseBackoff * 2 ^ msg.attempt
      let jittered  = rand(cast[int](nextDelay.inMilliseconds()))
      let delay     = min(reactor.debug.maxBackoff, jittered)
      msg.nextSend = now + initDuration(milliseconds = delay)
      msg.attempt += 1
      nextMessages.add(msg)

  reactor.toSend = nextMessages

proc readMessages(reactor: Reactor) =
  var
    buf = newStringOfCap(reactor.debug.maxUdpPacketSize)
    host: string
    port: Port

  # Try to read 1000 messages from the socket. This should probably be configurable
  # Once we're done reading packets, decode them and attempt to match up any acknowledgements
  # with outstanding sends
  # TODO - Make the message count here configurable
  for _ in 0 ..< 1000:
    var byteLen: int
    try:
      byteLen = reactor.socket.recvFrom(
        buf,
        reactor.debug.maxUdpPacketSize,
        host,
        port
      )
      echo "RECV_FROM: ", byteLen
    except:
      # TODO - WE need to throw a real error here probably. An error indicates
      # something has gone wrong with the socket
      break
    let address = initAddress(host, port)
    let message = messageFromBytes(buf, address)

    # If this is an ack than match it with any existing sends and move on
    var toDelete: seq[int] = @[]

    # Scan the toSend buffer and record their index if they match the id of the
    # message we just received. Once we're done we can delete each index from the
    # toSend buffer
    if message.mtype == MessageType.Ack:
      for i, toSend in reactor.toSend:
        if toSend.id == message.id:
          toDelete.add(i)

    for idx in toDelete:
      reactor.toSend.delete(idx)

    # Discard any rst messages for now.
    if message.mtype == MessageType.Con or message.mtype == MessageType.Non:
      reactor.messages.add(message)

proc tick*(reactor: Reactor) =
  reactor.messages.setLen(0)
  reactor.sendMessages()
  reactor.readMessages()

proc send(reactor: Reactor, message: Message) =
  # TODO - Return a proper error here so the user knows that they were dropped because our buffer is full
  if reactor.toSend.len >= reactor.debug.maxInFlight:
    return

  message.nextSend = getMonoTime()
  message.attempt = 1
  reactor.toSend.add(message)

proc getNextId*(reactor: Reactor): uint16 =
  reactor.id += 1
  return reactor.id

proc messageStatus*(reactor: Reactor, msgId: MsgId): MessageStatus =
  for m in reactor.toSend:
    if m.id == msgId:
      return MessageStatus.InFlight

  for failed in reactor.failedMessages:
    if failed.id == msgId:
      return MessageStatus.Failed

  # If we make it to this point we just return a Delivered status since
  # it was either a non-confirmable message or a confirmable message that was already
  # sent and didn't fail
  return MessageStatus.Delivered

proc genToken(): string =
  var token = newString(4)
  let bytes = urandom(4)
  for b in bytes:
    token.add(b.char)

proc ack*(message: Message, data: string): Message =
  result = Message()
  result.version = 0
  result.id = message.id
  result.token = message.token
  result.data = data
  result.mtype = MessageType.Ack
  result.address = message.address

proc confirm*(reactor: Reactor, address: Address, data: string): uint16 =
  let message     = Message()
  let id          = reactor.getNextId()
  message.mtype   = MessageType.Con
  message.id      = id
  message.token   = genToken()
  message.address = address
  message.data    = data
  reactor.send(message)
  return id
proc confirm*(reactor: Reactor, host: string, port: int, data: string): uint16 =
  let address = initAddress(host, port)
  confirm(reactor, address, data)

proc nonconfirm*(reactor: Reactor, address: Address, data: string): uint16 =
  let message     = Message()
  let id          = reactor.getNextId()
  message.mtype   = MessageType.Non
  message.id      = id
  message.token   = genToken()
  message.address = address
  message.data    = data
  reactor.send(message)
  return id
proc nonconfirm*(reactor: Reactor, host: string, port: int, data: string): uint16 =
  let address = initAddress(host, port)
  nonconfirm(reactor, address, data)

proc newReactor*(address: Address): Reactor =
  let debugInfo = DebugInfo(
    maxUdpPacketSize: defaultMaxUdpPacketSize,
    maxInFlight: defaultMaxInFlight,
    maxBackoff: defaultMaxBackoff,
    baseBackoff: defaultRetryDuration,
  )
  result = Reactor()
  result.socket = newSocket(
    AF_INET,
    SOCK_DGRAM,
    IPPROTO_UDP,
    buffered = false
  )
  result.id = 1
  result.socket.getFd().setBlocking(false)
  result.socket.bindAddr(address.port, address.host)
  result.debug = debugInfo

proc newReactor*(host: string, port: int): Reactor =
  newReactor(initAddress(host, port))

# Putting this here for now since its not attached to the underlying transport
# layer and I want to keep this isolated.
type
  RPC = tuple
    m: string
    params: seq[string]

when isMainModule:
  when defined(UdpServer):
    var
      i = 0
      sendNewMessage = true
      currentRPC: uint16 = 0

    echo "Starting reactor"
    let reactor = newReactor("127.0.0.1", 5557)

    while true:
      reactor.tick()

      let telemetry = pack(123)
      discard reactor.nonconfirm("127.0.0.1", 5555, telemetry)

      if sendNewMessage:
        echo "Sending RPC"

        sendNewMessage = false
        let rpc: RPC = ("yo", @[])
        let bin = pack(rpc)
        currentRPC = reactor.confirm("127.0.0.1", 5555, bin)
        echo "RPC ID ", currentRPC

      case reactor.messageStatus(currentRPC):
        of MessageStatus.Delivered:
          echo "RPC Success ", currentRPC
          currentRPC = 0
          sendNewMessage = true
        of MessageStatus.Failed:
          echo "RPC Failed ", currentRPC
          currentRPC = 0
          sendNewMessage = true
        of MessageStatus.InFlight:
          discard

      for msg in reactor.messages:
        echo "Got a new message", msg.id, " ", msg.data.len(), " ", msg.mtype

        var s = MsgStream.init(msg.data)
        var rpc = s.toJsonNode()
        echo "RPC: ", $rpc

        var buf = pack(123)
        let ack = msg.ack(buf)
        reactor.send(ack)

      i += 1
      sleep(1000)

  elif defined(UdpClient):
    var
      i = 0
      sendNewMessage = false
      currentRPC: uint16 = 0

    echo "Starting reactor"
    let reactor = newReactor("127.0.0.1", 5555)

    while true:
      reactor.tick()

      let telemetry = pack(123)
      discard reactor.nonconfirm("127.0.0.1", 5557, telemetry)


      for msg in reactor.messages:
        echo "Got a new message", msg.id, " ", msg.data.len(), " ", msg.mtype

        var s = MsgStream.init(msg.data)

        var rpc = s.toJsonNode()
        echo "RPC: ", $rpc

        var buf = pack(123)
        let ack = msg.ack(buf)
        reactor.send(ack)

      i += 1
      sleep(1000)

