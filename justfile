# Stagecoach test recipes. Suites live in tests/<layer>/ and are discovered by
# scripts/run-tests.sh; add a suite there, not to a list here.

default: test

# unit layer: no listening socket or subprocess (tests/unit/)
test-unit:
    bash scripts/run-tests.sh unit

# integration layer: fixture-server or self-hosted end-to-end (tests/integration/)
test-integration:
    bash scripts/run-tests.sh integration

test: test-unit test-integration

# run a single suite from any layer, e.g. `just test-one http`
test-one name:
    bash scripts/run-tests.sh one {{name}}

# concurrency / soak tests (release build, not part of `test`)
stress:
    bash scripts/run-tests.sh stress

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
