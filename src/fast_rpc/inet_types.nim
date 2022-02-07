import nativesockets, net, selectors, posix, tables
import endians

export nativesockets, net, selectors, posix, tables

import mcu_utils/logging
import mcu_utils/msgbuffer
import mcu_utils/eventfds

export eventfds

import json
export json

import threading/smartptrs
export smartptrs

type
  InetAddress* = object
    # Combined type for a remote IP address and service port
    host*: IpAddress
    port*: Port
    protocol*: net.Protocol
    socktype*: net.SockType

  CanMsgId* = object
    iface: int
    msgid: int

  InetClientType* = enum
    clSocket,
    clAddress,
    clCanBus

  InetClientObj* = object
    # Combined type for a remote IP address and service port
    case kind: InetClientType  # the `kind` field is the discriminator
    of clSocket:
      fd: SocketHandle
    of clAddress:
      host*: IpAddress
      port*: Port
    of clCanBus:
      msgid: CanMsgId

    protocol*: net.Protocol
    socktype*: net.SockType

  InetClientHandle* = ConstPtr[InetClientObj]

type 
  InetClientDisconnected* = object of OSError
  InetClientError* = object of OSError


proc newInetAddr*(host: string, port: int, protocol = net.IPPROTO_TCP): InetAddress =
  result.host = parseIpAddress(host)
  result.port = Port(port)
  result.protocol = protocol
  result.socktype = protocol.toSockType()

proc inetDomain*(inetaddr: InetAddress): nativesockets.Domain = 
  case inetaddr.host.family:
  of IpAddressFamily.IPv4:
    result = Domain.AF_INET
  of IpAddressFamily.IPv6:
    result = Domain.AF_INET6 

proc newClientHandle*(fd: SocketHandle, protocol = net.IPPROTO_TCP): InetClientHandle =
  result = newConstPtr InetClientObj(
    kind: clSocket,
    fd: fd,
    protocol: protocol,
    socktype: protocol.toSockType(),
  )

proc newClientHandle*(host: IpAddress, port: Port, protocol = net.IPPROTO_UDP): InetClientHandle =
  result = newConstPtr InetClientObj(
    kind: clAddress,
    host: host,
    port: port,
    protocol: protocol,
    socktype: protocol.toSockType(),
  )

proc newClientHandle*(host: string, port: int, protocol = net.IPPROTO_UDP): InetClientHandle =
  result = newConstPtr InetClientObj(
    kind: clAddress,
    host: parseIpAddress(host),
    port: Port(port),
    protocol: protocol,
    socktype: protocol.toSockType(),
  )

proc newClientHandle*(msgid: CanMsgId, protocol = net.IPPROTO_RAW): InetClientHandle =
  result = newConstPtr InetClientObj(
    kind: clCanBus,
    msgid: msgid,
    protocol: protocol,
    socktype: protocol.toSockType(),
  )
