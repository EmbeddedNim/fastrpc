# Package

version       = "0.2.0"
author        = "Jaremy Creechley"
description   = "fast binary rpc designed for embedded"
license       = "Apache-2.0"
srcDir        = "src"


# Dependencies

requires "nim >= 1.6.5"
requires "stew >= 0.1.0"
requires "progress >= 0.1.0"
requires "msgpack4nim >= 0.3.1"
requires "threading >= 0.1.0"
requires "cligen >= 0.1.0"
requires "https://github.com/EmbeddedNim/mcu_utils#head"

task build_integration_tests, "build integration test tools":
  exec "nim c tests/integration/fastrpcserverExample.nim"
  exec "nim c tests/integration/fastrpccli.nim"
  exec "nim c tests/integration/rpcmpackpubsubserver.nim"
  # exec "nim c tests/integration/rpcmpackserver.nim"
  # exec "nim c tests/integration/rpcmpackcli.nim"
  exec "nim c tests/integration/tcpechoserver.nim"
  exec "nim c tests/integration/udpechoserver.nim"
  exec "nim c tests/integration/combechoserver.nim"

after test:
  build_integration_testsTask()
