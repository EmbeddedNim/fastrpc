
import fastrpc/socketserver
import fastrpc/socketserver/echo_udp_impl


when isMainModule:
  let inetAddrs = [
    newInetAddr("0.0.0.0", 31337, Protocol.IPPROTO_UDP),
  ]

  startSocketServer(inetAddrs, newEchoUdpServer(prefix="echo> "))
