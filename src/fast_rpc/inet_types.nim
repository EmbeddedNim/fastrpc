import nativesockets, net, selectors, posix, tables
import endians

export nativesockets, net, selectors, posix, tables

import mcu_utils/logging
import mcu_utils/msgbuffer

import json
export json

type
  InetAddress* = object
    # Combined type for a remote IP address and service port
    host*: IpAddress
    port*: Port
    protocol*: net.Protocol
    socktype*: net.SockType


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