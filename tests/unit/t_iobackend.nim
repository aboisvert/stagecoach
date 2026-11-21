## Compile-time backend selection for Stagecoach workers.
import std/unittest
import stagecoach/iobackend

suite "I/O backend selection":
  test "the compiled policy matches the requested backend":
    when defined(stagecoachIoUring):
      check ioBackendPolicy == requireIoUring
    elif defined(stagecoachReadiness):
      check ioBackendPolicy == requireReadiness
    elif defined(linux):
      check ioBackendPolicy == preferIoUring
    else:
      check ioBackendPolicy == requireReadiness
