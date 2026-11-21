## Preserve the test binary's backend selection in compiled fixture servers.
const backendBuildFlag* =
  when defined(stagecoachIoUring): " -d:stagecoachIoUring"
  elif defined(stagecoachReadiness): " -d:stagecoachReadiness"
  else: ""
