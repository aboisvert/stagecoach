# Stagecoach test recipes. Every suite builds into bin/.
nim := "nim c -r --hints:off --threads:on --outdir:bin"

default: test

# pure unit + in-process socketpair suites
test-unit:
    {{nim}} tests/t_core.nim
    {{nim}} tests/t_parser.nim
    {{nim}} tests/t_io.nim
    {{nim}} tests/t_response.nim
    {{nim}} tests/t_pollfd.nim

# suites that spawn bin/fixture_server (tests/fixture_server.nim)
test-integration:
    {{nim}} tests/t_http.nim
    {{nim}} tests/t_modes.nim
    {{nim}} tests/t_limits.nim
    {{nim}} tests/t_shutdown.nim
    {{nim}} tests/t_stop.nim
    {{nim}} tests/t_stream.nim

test: test-unit test-integration

# run a single suite, e.g. `just test-one http`
test-one name:
    {{nim}} tests/t_{{name}}.nim

# concurrency / soak tests (release build, not part of `test`)
stress:
    nim c -r -d:release --hints:off --threads:on --outdir:bin tests/t_stress.nim

# compile every example without running it
examples:
    for f in examples/*.nim; do nim c --hints:off --threads:on --outdir:bin "$f" || exit 1; done

# Linux tests on macOS via Docker
linux-build:
    scripts/linux-test.sh build

linux-test *args:
    scripts/linux-test.sh test {{args}}

linux-shell:
    scripts/linux-test.sh shell

linux-bench *args:
    scripts/linux-test.sh bench {{args}}

linux-clean:
    scripts/linux-test.sh clean
