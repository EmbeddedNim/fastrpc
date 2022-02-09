import os, random
import nativesockets, net

import sugar

import fastrpc/socketserver/sockethelpers

proc producerThread(args: (Socket, int, int)) =
  var
    sock = args[0]
    count = args[1]
    tsrand = args[2]
  echo "\n===== running producer ===== "
  for i in 0..<count:
    os.sleep(rand(tsrand))
    # /* create data item to send */
    var txData = 1234 + 100 * i

    # /* send data to consumers */
    echo "-> Producer: tx_data: putting: ", i, " -> ", repr(txData)
    sock.send($txData&"\n")
    echo "-> Producer: tx_data: sent: ", i
  echo "Done Producer: "
  
proc consumerThread(args: (Socket, int, int)) =
  var
    sock = args[0]
    count = args[1]
    tsrand = args[2]
  echo "\n===== running consumer ===== "
  for i in 0..<count:
    os.sleep(rand(tsrand))
    echo "<- Consumer: rx_data: wait: ", i
    var rxData = sock.recvLine()
    # var
    #   rxData = newString(100)
    #   ipaddr: IpAddress
    #   port: Port

    # discard sock.recvFrom(rxData, rxData.len(), ipaddr, port, 0)
    # dump((ipaddr, port))

    echo "<- Consumer: rx_data: got: ", i, " <- ", repr(rxData)

  echo "Done Consumer "

proc runTestsChannelThreaded*(ncnt, tsrand: int) =
  echo "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< "
  echo "[Channel] Begin "
  randomize()
  let sockets = newSocketPair(sockType = SockType.SOCK_DGRAM, protocol = Protocol.IPPROTO_IP)

  var thrp: Thread[(Socket, int, int)]
  var thrc: Thread[(Socket, int, int)]

  createThread(thrc, consumerThread, (sockets[0], ncnt, tsrand))
  # os.sleep(2000)
  createThread(thrp, producerThread, (sockets[1], ncnt, tsrand))
  joinThreads(thrp, thrc)
  echo "[Channel] Done joined "
  echo ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> "

when isMainModule:
  runTestsChannelThreaded(7, 0)
