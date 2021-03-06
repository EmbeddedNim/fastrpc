import tables
import mcu_utils/msgbuffer
import mcu_utils/inettypes
import mcu_utils/inetqueues

export tables, inettypes, inetqueues, msgbuffer

type
  FastErrorCodes* = enum
    # Error messages
    FAST_PARSE_ERROR = -27
    INVALID_REQUEST = -26
    METHOD_NOT_FOUND = -25
    INVALID_PARAMS = -24
    INTERNAL_ERROR = -23
    SERVER_ERROR = -22

  FastRpcParamsBuffer* = object
    ## implementation specific -- handles data buffer
    buf*: MsgBuffer 


type
  FastRpcType* {.size: sizeof(uint8).} = enum
    # Fast RPC Types
    Request       = 5
    Response      = 6
    Notify        = 7
    Error         = 8
    Subscribe     = 9
    Publish       = 10
    SubscribeStop = 11
    PublishDone   = 12
    SystemRequest = 19
    Unsupported   = 23
    # rtpMax = 23 # numbers less than this store in single mpack/cbor byte

  FastRpcId* = int

  FastRpcRequest* = object
    kind*: FastRpcType
    id*: FastRpcId
    procName*: string
    params*: FastRpcParamsBuffer # - we handle params below

  FastRpcResponse* = object
    kind*: FastRpcType
    id*: int
    result*: FastRpcParamsBuffer # - we handle params below

  FastRpcError* = ref object
    code*: FastErrorCodes
    msg*: string
    trace*: seq[(string, string, int)]


## MsgPack serde implementations ##

proc pack_type*[ByteStream](s: ByteStream, x: FastRpcParamsBuffer) =
  s.write(x.buf.data, x.buf.pos)

proc unpack_type*[ByteStream](s: ByteStream, x: var FastRpcParamsBuffer) =
  var params = s.readStrRemaining()
  x.buf = MsgBuffer.init()
  shallowCopy(x.buf.data, params)
