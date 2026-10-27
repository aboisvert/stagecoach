version       = "9.0.2"
author        = "Olli"
description   = "Modular multithreading HTTP/1.1 + WebSocket upstream server framework"
license       = "MIT"

skipDirs = @["docs", "examples"]

# `nimble build` compiles binaries listed here. guildenstern.nim imports the
# library modules, so this compiles the library. Output goes to bin/.
binDir = "bin"
bin = @["guildenstern"]

requires "nim >= 2.0.0"

proc compileAndRunExample(name: string, flags = "") =
  exec "nim c -r --hints:off --outdir:bin " & flags & " examples/" & name & ".nim"

task helloworld, "Compile and run examples/helloworld.nim":
  compileAndRunExample("helloworld")

task getandpost, "Compile and run examples/getandpost.nim":
  compileAndRunExample("getandpost")

task httptest, "Compile and run examples/httptest.nim":
  compileAndRunExample("httptest")

task wsmulticasttest, "Compile and run examples/wsmulticasttest.nim":
  compileAndRunExample("wsmulticasttest", "-d:release --mm:atomicArc")
