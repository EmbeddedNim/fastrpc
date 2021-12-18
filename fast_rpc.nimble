# Package

version       = "0.1.0"
author        = "Jaremy Creechley"
description   = "fast rpc designed for embedded"
license       = "Apache-2.0"
srcDir        = "src"


# Dependencies

requires "nim >= 1.6.0"
requires "stew >= 0.1.0"
requires "progress >= 0.1.0"
requires "mcu_utils >= 0.1.0"

task build_integration_tests, "build integration test tools":
  exec "nim c tests/integration/multicastserver.nim"
  exec "nim c tests/integration/multicastclient.nim"
  exec "nim c tests/integration/rpcmpackpubsubserver.nim"
  exec "nim c tests/integration/rpcmpackserver.nim"
  exec "nim c tests/integration/rpcmpackcli.nim"
  exec "nim c tests/integration/tcpechoserver.nim"
  exec "nim c tests/integration/udpechoserver.nim"
  exec "nim c tests/integration/combechoserver.nim"

