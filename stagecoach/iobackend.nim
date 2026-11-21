## Compile-time policy for selecting a worker's I/O backend.

when defined(stagecoachIoUring) and defined(stagecoachReadiness):
  {.error: "stagecoachIoUring and stagecoachReadiness are mutually exclusive".}
when defined(stagecoachIoUring) and not defined(linux):
  {.error: "stagecoachIoUring requires Linux".}

type IoBackendPolicy* = enum
  preferIoUring, requireIoUring, requireReadiness

const ioBackendPolicy* =
  when defined(stagecoachIoUring):
    requireIoUring
  elif defined(stagecoachReadiness) or not defined(linux):
    requireReadiness
  else:
    preferIoUring
