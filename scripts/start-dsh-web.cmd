@echo off
setlocal

echo Starting DeepSeek Harness Web...
echo The first launch normally takes 30-90 seconds.
echo When ready, open http://127.0.0.1:3080
echo.

call npx --yes @deepseek-ai/dsh web %*

endlocal
