version       = "0.2"
author        = "Alex Boisvert"
description   = "HTTP/1.1 server on the stagelane M:N async runtime (HTTP only on this branch)"
license       = "MIT"

skipDirs = @["examples"]


requires "nim >= 2.2.0"
requires "https://github.com/ghazalialshafi/stagelane#f5b7cad5babd884baf9b21f8ea11ee9558d02cff"

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

task test, "Run all discovered suites (unit + integration; `just stress` for soak)":
  exec "bash scripts/run-tests.sh all"

task stress, "Run the stress / soak suite":
  exec "bash scripts/run-tests.sh stress"
