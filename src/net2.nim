import std/nativesockets
import std/net
import std/os

const defineSsl = defined(ssl) or defined(nimdoc)

type

  InetPort* = distinct uint16 ## port type (network byte order)

  InetAddress* = object                 ## stores an arbitrary network address
    case domain*: Domain      ## the type of the IP address (IPv4 or IPv6)
    of Domain.AF_INET6:
      port_v6*: InetPort
      address_v6*: array[0..15, uint8] ## Contains the IP address in bytes in
                                       ## case of IPv6
      scope_id*: uint32                ## Contains the IPv6 scope id per rfc3493
                                       ## and is generally the index of the 
                                       ## network interface. Also rfc6874
      flowinfo*: uint32                ## IPv6 traffic class and flow information.
    of Domain.AF_INET:
      port_v4*: InetPort
      address_v4*: array[0..3, uint8]  ## Contains the IP address in bytes in
                                       ## case of IPv4
    of Domain.AF_UNIX:
      path*: string
    of Domain.AF_UNSPEC:
      family*: cuint
      port_unspec*: string
      address_unspec*: string


#[
proc connect*(
    socket: Socket,
) {.tags: [ReadIOEffect].} =
  ## Connects socket to `address`:`port`. `Address` can be an IP address or a
  ## host name. If `address` is a host name, this function will try each IP
  ## of that host name. `htons` is already performed on `port` so you must
  ## not do it.
  ##
  ## If `socket` is an SSL socket a handshake will be automatically performed.
  var aiList = getAddrInfo(address, port, socket.domain)
  # try all possibilities:
  var success = false
  var lastError: OSErrorCode
  var it = aiList
  while it != nil:
    if connect(socket.getFd(), it.ai_addr, it.ai_addrlen.SockLen) == 0'i32:
      success = true
      break
    else: lastError = osLastError()
    it = it.ai_next

  freeaddrinfo(aiList)
  if not success: raiseOSError(lastError)

  when defineSsl:
    if socket.isSsl:
      # RFC3546 for SNI specifies that IP addresses are not allowed.
      if not isIpAddress(address):
        # Discard result in case OpenSSL version doesn't support SNI, or we're
        # not using TLSv1+
        discard SSL_set_tlsext_host_name(socket.sslHandle, address)

      ErrClearError()
      let ret = SSL_connect(socket.sslHandle)
      socketError(socket, ret)
      when not defined(nimDisableCertificateValidation) and not defined(windows):
        if not isIpAddress(address):
          socket.checkCertName(address)

proc toSockAddr*(address: IpAddress, port: Port, sa: var Sockaddr_storage,
                 sl: var SockLen) =
  ## Converts `IpAddress` and `Port` to `SockAddr` and `SockLen`
  let port = htons(uint16(port))
  case address.family
  of IpAddressFamily.IPv4:
    sl = sizeof(Sockaddr_in).SockLen
    let s = cast[ptr Sockaddr_in](addr sa)
    s.sin_family = typeof(s.sin_family)(toInt(AF_INET))
    s.sin_port = port
    copyMem(addr s.sin_addr, unsafeAddr address.address_v4[0],
            sizeof(s.sin_addr))
  of IpAddressFamily.IPv6:
    sl = sizeof(Sockaddr_in6).SockLen
    let s = cast[ptr Sockaddr_in6](addr sa)
    s.sin6_family = typeof(s.sin6_family)(toInt(AF_INET6))
    s.sin6_port = port
    copyMem(addr s.sin6_addr, unsafeAddr address.address_v6[0],
            sizeof(s.sin6_addr))

proc fromSockAddrAux(sa: ptr Sockaddr_storage, sl: SockLen,
                     address: var IpAddress, port: var Port) =
  if sa.ss_family.cint == toInt(AF_INET) and sl == sizeof(Sockaddr_in).SockLen:
    address = IpAddress(family: IpAddressFamily.IPv4)
    let s = cast[ptr Sockaddr_in](sa)
    copyMem(addr address.address_v4[0], addr s.sin_addr,
            sizeof(address.address_v4))
    port = ntohs(s.sin_port).Port
  elif sa.ss_family.cint == toInt(AF_INET6) and
       sl == sizeof(Sockaddr_in6).SockLen:
    address = IpAddress(family: IpAddressFamily.IPv6)
    let s = cast[ptr Sockaddr_in6](sa)
    copyMem(addr address.address_v6[0], addr s.sin6_addr,
            sizeof(address.address_v6))
    port = ntohs(s.sin6_port).Port
  else:
    raise newException(ValueError, "Neither IPv4 nor IPv6")

proc fromSockAddr*(sa: Sockaddr_storage | SockAddr | Sockaddr_in | Sockaddr_in6,
    sl: SockLen, address: var IpAddress, port: var Port) {.inline.} =
  ## Converts `SockAddr` and `SockLen` to `IpAddress` and `Port`. Raises
  ## `ObjectConversionDefect` in case of invalid `sa` and `sl` arguments.
  fromSockAddrAux(cast[ptr Sockaddr_storage](unsafeAddr sa), sl, address, port)

]#
