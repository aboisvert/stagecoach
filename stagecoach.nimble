version       = "0.1"
author        = "Alex Boisvert"
description   = "HTTP/1.1 server on the stagelane M:N async runtime (HTTP only on this branch)"
license       = "MIT"

skipDirs = @["examples"]


requires "nim >= 2.2.0"
requires "https://github.com/ghazalialshafi/stagelane#head"

proc compileAndRunExample(name: string, flags = "") =
  exec "nim c -r --hints:off --outdir:bin " & flags & " examples/" & name & ".nim"

task helloworld, "Compile and run examples/helloworld.nim":
  compileAndRunExample("helloworld")

task getandpost, "Compile and run examples/getandpost.nim":
  compileAndRunExample("getandpost")

task httptest, "Compile and run examples/httptest.nim":
  compileAndRunExample("httptest")

task asynchandler, "Compile and run examples/asynchandler.nim":
  compileAndRunExample("asynchandler")

task querybench, "Compile and run examples/querybench.nim":
  compileAndRunExample("querybench")

task test, "Run stagecoach tests":
  exec "nim c -r --hints:off tests/t_parser.nim"
  exec "nim c -r --hints:off tests/t_socket.nim"
  exec "nim c -r --hints:off tests/t_stop.nim"
  exec "nim c -r --hints:off tests/t_stream.nim"
