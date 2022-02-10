
import fastrpc/socketserver
import fastrpc/socketservers/echo_comb_impl

# import nimprof

when isMainModule:
  let inetAddrs = [
    newInetAddr("0.0.0.0", 31337, Protocol.IPPROTO_UDP),
    newInetAddr("0.0.0.0", 31337, Protocol.IPPROTO_TCP),
  ]

  startSocketServer(inetAddrs, newEchoServer(prefix="echo> "))
