## Compile-time policy for selecting a worker's I/O backend.

when defined(stagecoachIoUring) and defined(stagecoachEpoll):
  {.error: "stagecoachIoUring and stagecoachEpoll are mutually exclusive".}
when defined(stagecoachIoUring) and not defined(linux):
  {.error: "stagecoachIoUring requires Linux".}

type IoBackendPolicy* = enum
  preferIoUring, requireIoUring, requireEpoll

const ioBackendPolicy* =
  when defined(stagecoachIoUring):
    requireIoUring
  elif defined(stagecoachEpoll) or not defined(linux):
    requireEpoll
  else:
    preferIoUring