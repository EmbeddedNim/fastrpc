
import fast_rpc/socketserver
import fast_rpc/socketserver/echo_tcp_server


when isMainModule:
  let inetAddrs = [
    newInetAddr("0.0.0.0", 31337),
  ]

  startSocketServer(inetAddrs, newEchoTcpServer(prefix="echo> "))
