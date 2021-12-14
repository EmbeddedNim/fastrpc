import nativesockets, net, selectors, posix, tables

export nativesockets, net, selectors, posix, tables

type
  InetAddress* = object
    # Combined type for a remote IP address and service port
    host*: IpAddress
    port*: Port

  SocketServerInfo*[T] = ref object 
    select*: Selector[T]
    servers*: seq[Socket]
    clients*: ref Table[SocketHandle, Socket]
    writeHandler*: SocketServerHandler[T]
    readHandler*: SocketServerHandler[T]

  SocketServerHandler*[T] = proc (srv: SocketServerInfo[T],
                                  selected: ReadyKey,
                                  client: Socket,
                                  data: T) {.nimcall.}


type 
  InetClientDisconnected* = object of OSError
  InetClientError* = object of OSError
