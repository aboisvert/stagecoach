## Compile-time backend selection for Stagecoach workers.
import std/unittest
import stagecoach/iobackend

suite "I/O backend selection":
  test "the compiled policy matches the requested backend":
    when defined(stagecoachIoUring):
      check ioBackendPolicy == requireIoUring
    elif defined(stagecoachEpoll):
      check ioBackendPolicy == requireEpoll
    elif defined(linux):
      check ioBackendPolicy == preferIoUring
    else:
      check ioBackendPolicy == requireEpoll