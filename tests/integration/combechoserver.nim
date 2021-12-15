
import fast_rpc/socketserver
import fast_rpc/socketserver/echo_comb_server


when isMainModule:
  let inetAddrs = [
    newInetAddr("0.0.0.0", 31337, Protocol.IPPROTO_UDP),
  ]

  startSocketServer(inetAddrs, newEchoServer(prefix="echo> "))
