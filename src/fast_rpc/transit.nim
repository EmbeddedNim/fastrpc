# TODO - These imports probably don't work on zephyr so we should fix that
import system
import std/net
import std/monotimes
import std/times
import nativesockets
import os
import msgpack4nim
import std/sysrand
import std/random
import math

import binutils

const
  defaultMaxUdpPacketSize = 1500
  defaultMaxInFlight = 2000 # Arbitrary number of packets in flight that we'll allow
  defaultMaxBackoff = 5_000
  defaultRetryDuration = initDuration(milliseconds = 250)

# Splitting up these type definitions since I want to be able to extract this
# stuff later.
type
  MsgId* = distinct uint16
  MsgToken* = distinct string

  Address* = object
    host*: string
    port*: Port

  MessageType = enum
    Con, Non, Ack, Rst

  Message* = ref object
    address*: Address
    version*: uint8
    id*: MsgId
    mtype*: MessageType
    token*: MsgToken
    data*: string
    acked: bool
    nextSend: MonoTime
    attempt: int

  DebugInfo* = object
    maxUdpPacketSize: int
    maxInFlight: int
    maxBackoff: int
    baseBackoff: Duration

  Reactor* = ref object
    id*: MsgId
    socket: Socket
    time: float64
    maxInFlight: int
    failedMessages*: seq[Message]
    messages*: seq[Message]
    toSend: seq[Message]
    queueSize: int
    debug: DebugInfo

proc `==` *(x, y: MsgId): bool {.borrow.}
proc `==` *(x, y: MsgToken): bool {.borrow.}
proc `$` *(x: MsgId): string {.borrow.}
proc `$` *(x: MsgToken): string {.borrow.}

proc initAddress*(host: string, port: Port): Address =
  result.host = host
  result.port = port

proc initAddress*(host: string, port: int): Address =
  result.host = host
  result.port = Port(port)

proc ack*(message: Message, data: string): Message =
  result = Message()
  result.version = 0
  result.id = message.id
  result.token = message.token
  result.data = data
  result.mtype = MessageType.Ack
  result.address = message.address

proc messageToBytes(message: Message, buf: var MsgBuffer) =
  let ver = message.version shl 6
  let typ = message.mtype.uint8() shl 4
  let tkl = uint8(message.token.string.len())

  let verTypeTkl = ver or typ or tkl
  buf.write(verTypeTkl.char)

  # Adding the id. Extend the buffer by the correct amount and add the 2 bytes
  buf.store16(message.id.uint16)

  buf.write(message.token)

  if message.data != "":
    buf.write(0xFF.char)
    buf.write(message.data)

proc messageFromBytes(buf: var MsgBuffer, address: Address): Message =
  result = Message()

  let
    verTypeTkl = uint8(buf.readChar())
    version = verTypeTkl shr 6

  result.version = version
  result.mtype = MessageType((0b0011_0000 and verTypeTkl) shr 4)

  let tkl: int = int(0b0000_1111 and verTypeTkl)
  assert tkl == sizeof(MsgToken)

  # Read 2 bytes for the id. These are in little endian so swap them
  # to get the id in network order
  result.id = MsgId(buf.unstore16())

  # Read Token
  result.token = MsgToken(buf.readStr(tkl))

  if buf.readChar().uint8 == 0xFF:
    result.data = buf.readStrRemaining()

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

    var buf = MsgBuffer.init(reactor.debug.maxUdpPacketSize)
    messageToBytes(msg, buf)
    reactor.socket.sendTo(msg.address.host, msg.address.port, buf.data)

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

  # Try to read queueSize messages from the socket. This should probably be configurable
  # Once we're done reading packets, decode them and attempt to match up any acknowledgements
  # with outstanding sends
  for _ in 0 ..< reactor.queueSize:
    var byteLen: int
    try:
      byteLen = reactor.socket.recvFrom(
        buf,
        reactor.debug.maxUdpPacketSize,
        host,
        port
      )
    except:
      # TODO - WE need to throw a real error here probably. An error indicates
      # something has gone wrong with the socket
      break
  
    var
      msgBuf = MsgBuffer.init(buf) # performs shallow copy!
    let
      address = initAddress(host, port)
      message = messageFromBytes(msgBuf, address)

    # If this is an ack than match it with any existing sends and move on
    var toDelete = newSeq[int]()

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
  # TODO - implement smarter guarding against adding a message if our buffer is "full".
  # TODO - Return a proper error here so the user knows that they were dropped
  if reactor.toSend.len >= reactor.debug.maxInFlight:
    return

  message.nextSend = getMonoTime()
  message.attempt = 1
  reactor.toSend.add(message)

proc getNextId*(reactor: Reactor): MsgId =
  reactor.id.inc()
  return reactor.id

type MessageStatus = enum
  InFlight, Delivered, Failed

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


proc genToken(reactor: Reactor): MsgToken =
  var token = newString(4)
  let bytes = urandom(4)
  for b in bytes:
    token.add(b.char)
  result = MsgToken(token)

proc confirm*(reactor: Reactor, host: string, port: int, data: string): MsgId =
  let address = initAddress(host, port)
  let message = Message()
  let id = reactor.getNextId()
  message.mtype = MessageType.Con
  message.id = id
  message.token = reactor.genToken()
  message.address = address
  message.data = data
  reactor.send(message)
  return id

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
  result.id = 1.MsgId
  result.socket.getFd().setBlocking(false)
  result.socket.bindAddr(address.port, address.host)
  result.maxInFlight = defaultMaxInFlight
  result.debug = debugInfo

proc newReactor*(host: string, port: int): Reactor =
  newReactor(initAddress(host, port))

type
  RPC = tuple
    m: string
    params: seq[string]

when isMainModule:
  echo "Starting reactor"
  let reactor = newReactor("127.0.0.1", 5557)
  var i = 0
  var sendNewMessage = true
  var currentRPC: MsgId

  while true:
    reactor.tick()

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
        currentRPC = 0.MsgId
        sendNewMessage = true
      of MessageStatus.Failed:
        echo "RPC Failed ", currentRPC
        currentRPC = 0.MsgId
        sendNewMessage = true
      of MessageStatus.InFlight:
        discard

    for msg in reactor.messages:
      echo "Got a new message", msg.id, " ", msg.data, " ", msg.mtype

      var s = MsgStream.init(msg.data)
      var rpc: RPC
      s.unpack(rpc)
      echo "RPC: ", rpc

      var buf = pack(123)
      let ack = msg.ack(buf)
      reactor.send(ack)

    inc(i)
    sleep(100)

