
import fastrpc/socketserver
import fastrpc/socketserver/echo_tcp_impl


when isMainModule:
  let inetAddrs = [
    newInetAddr("0.0.0.0", 31337),
  ]

  startSocketServer(inetAddrs, newEchoTcpServer(prefix="echo> "))
