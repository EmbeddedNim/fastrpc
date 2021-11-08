# MessagePack implementation written in nim
#
# Copyright (c) 2015-2019 Andri Lim
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
#
#-------------------------------------
when not declared SomeFloat:
  type
    SomeFloat = SomeReal

import endians, macros, streams

const pack_value_nil* = chr(0xc0)

type

  MsgBuffer* = ref object
    data*: string
    pos*: int

proc initMsgBuffer*(x: typedesc[MsgBuffer], cap: int = 0): MsgBuffer =
  result = new(x)
  result.data = newStringOfCap(cap)
  result.pos = 0

proc initMsgBuffer*(x: typedesc[MsgBuffer], data: owned string): MsgBuffer =
  result = new(x)
  # shallowCopy(result.data, data)
  result.data = data
  result.pos = 0

proc writeData(s: MsgBuffer, buffer: pointer, bufLen: int) =
  if bufLen <= 0: return
  if s.pos + bufLen > s.data.len:
    setLen(s.data, s.pos + bufLen)
  copyMem(addr(s.data[s.pos]), buffer, bufLen)
  inc(s.pos, bufLen)

proc write*[T](s: MsgBuffer, val: T) =
  var y: T
  shallowCopy(y, val)
  writeData(s, addr(y), sizeof(y))

proc write*(s: MsgBuffer, val: string) =
  if val.len > 0: writeData(s, unsafeAddr val[0], val.len)

proc readData(s: MsgBuffer, buffer: pointer, bufLen: int): int =
  result = min(bufLen, s.data.len - s.pos)
  if result > 0:
    copyMem(buffer, addr(s.data[s.pos]), result)
    inc(s.pos, result)
  else:
    result = 0

proc read*[T](s: MsgBuffer, result: var T) =
  if s.readData(addr(result), sizeof(T)) != sizeof(T):
    doAssert(false)

proc readStr*(s: MsgBuffer, length: int): string =
  result = newString(length)
  if length != 0:
    var L = s.readData(addr(result[0]), length)
    if L != length: raise newException(IOError, "string len mismatch")

proc readChar*(s: MsgBuffer): char =
  s.read(result)

proc readInt16*(s: MsgBuffer): int16 =
  s.read(result)

proc readInt32*(s: MsgBuffer): int32 =
  s.read(result)

proc readInt64*(s: MsgBuffer): int64 =
  s.read(result)

proc peekChar*(s: MsgBuffer): char =
  if s.pos < s.data.len: result = s.data[s.pos]
  else: result = chr(0)

proc setPosition*(s: MsgBuffer, pos: int) =
  s.pos = clamp(pos, 0, s.data.len)

proc atEnd*(s: MsgBuffer): bool =
  return s.pos >= s.data.len

template skipUndistinct* {.pragma, deprecated.}
  # no need to use this pragma anymore
  # the undistinct macro is more clever now

proc getParamIdent(n: NimNode): NimNode =
  n.expectKind({nnkIdent, nnkVarTy, nnkSym})
  if n.kind in {nnkIdent, nnkSym}:
    result = n
  else:
    result = n[0]

proc hasDistinctImpl*(w: NimNode, z: NimNode): bool =
  for k in w:
    let p = k.getImpl()[3][2][1]
    if p.kind in {nnkIdent, nnkVarTy, nnkSym}:
      let paramIdent = getParamIdent(p)
      if eqIdent(paramIdent, z): return true

proc needToSkip(typ: NimNode | typedesc, w: NimNode): bool {.compileTime.} =
  let z = getType(typ)[1]

  if z.kind == nnkSym:
    if hasDistinctImpl(w, z): return true

  if z.kind != nnkSym: return false
  let impl = getImpl(z)
  if impl.kind != nnkTypeDef: return false
  if impl[2].kind != nnkDistinctTy: return false
  if impl[0].kind != nnkPragmaExpr: return false
  let prag = impl[0][1][0]
  result = eqIdent("skipUndistinct", prag)

#this macro convert any distinct types to it's base type
macro undistinctImpl*(x: typed, typ: typedesc, w: typed): untyped =
  var ty = getType(x)
  if needToSkip(typ, w):
    result = x
    return
  var isDistinct = ty.typekind == ntyDistinct
  if isDistinct:
    let parent = ty[1]
    result = quote do: `parent`(`x`)
  else:
    result = x

template undistinct_pack*(x: typed): untyped =
  undistinctImpl(x, type(x), bindSym("pack_type", brForceOpen))

template undistinct_unpack*(x: typed): untyped =
  undistinctImpl(x, type(x), bindSym("unpack_type", brForceOpen))

when system.cpuEndian == littleEndian:
  proc take8_8*(val: uint8): uint8 {.inline.} = val
  proc take8_16*(val: uint16): uint8 {.inline.} = uint8(val and 0xFF)
  proc take8_32*(val: uint32): uint8 {.inline.} = uint8(val and 0xFF)
  proc take8_64*(val: uint64): uint8 {.inline.} = uint8(val and 0xFF)

  proc store16*[ByteStream](s: ByteStream, val: uint16) =
    var res: uint16
    swapEndian16(addr(res), unsafeAddr(val))
    s.write(res)
  proc store32*[ByteStream](s: ByteStream, val: uint32) =
    var res: uint32
    swapEndian32(addr(res), unsafeAddr(val))
    s.write(res)
  proc store64*[ByteStream](s: ByteStream, val: uint64) =
    var res: uint64
    swapEndian64(addr(res), unsafeAddr(val))
    s.write(res)
  proc unstore16*[ByteStream](s: ByteStream): uint16 =
    var tmp: uint16 = cast[uint16](s.readInt16)
    swapEndian16(addr(result), addr(tmp))
  proc unstore32*[ByteStream](s: ByteStream): uint32 =
    var tmp: uint32 = cast[uint32](s.readInt32)
    swapEndian32(addr(result), addr(tmp))
  proc unstore64*[ByteStream](s: ByteStream): uint64 =
    var tmp: uint64 = cast[uint64](s.readInt64)
    swapEndian64(addr(result), addr(tmp))
else:
  proc take8_8*(val: uint8): uint8 {.inline.} = val
  proc take8_16*(val: uint16): uint8 {.inline.} = (val shr 8) and 0xFF
  proc take8_32*(val: uint32): uint8 {.inline.} = (val shr 24) and 0xFF
  proc take8_64*(val: uint64): uint8 {.inline.} = uint8((val shr 56) and 0xFF)

  proc store16*[ByteStream](s: ByteStream, val: uint16) = s.write(val)
  proc store32*[ByteStream](s: ByteStream, val: uint32) = s.write(val)
  proc store64*[ByteStream](s: ByteStream, val: uint64) = s.write(val)
  proc unstore16*[ByteStream](s: ByteStream): uint16 = cast[uint16](s.readInt16)
  proc unstore32*[ByteStream](s: ByteStream): uint32 = cast[uint32](s.readInt32)
  proc unstore64*[ByteStream](s: ByteStream): uint64 = cast[uint64](s.readInt64)

proc take8_8*[T:uint8|char|int8](val: T): uint8 {.inline.} = uint8(val)
proc take16_8*[T:uint8|char|int8](val: T): uint16 {.inline.} = uint16(val)
proc take32_8*[T:uint8|char|int8](val: T): uint32 {.inline.} = uint32(val)
proc take64_8*[T:uint8|char|int8](val: T): uint64 {.inline.} = uint64(val)
