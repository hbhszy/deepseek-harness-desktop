@echo off
setlocal

echo Starting DeepSeek Harness Web...
echo The first launch normally takes 30-90 seconds.
echo When ready, open http://127.0.0.1:3080
echo.

set "NO_COLOR=1"
set "FORCE_COLOR=0"

call pnpm dlx --reporter append-only ^
  --allow-build="@deepseek-ai/dsh-subprocess-local" ^
  --allow-build="@google/genai" ^
  --allow-build="koffi" ^
  --allow-build="node-pty" ^
  --allow-build="protobufjs" ^
  "@deepseek-ai/dsh" web --no-open %*

endlocal
