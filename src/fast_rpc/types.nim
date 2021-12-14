import std/net

type
  IpServiceAddress* = object
    # Combined type for a remote IP address and service port
    host*: IpAddress
    port*: Port
