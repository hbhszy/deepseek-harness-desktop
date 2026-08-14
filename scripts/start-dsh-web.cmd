@echo off
setlocal

rem Work around the peer-dependency packaging issue in @deepseek-ai/dsh 0.1.0-rc.6.
set "npm_config_registry=https://registry.npmjs.org/"
set "npm_config_legacy_peer_deps=true"

echo Starting DeepSeek Harness Web...
echo The first launch normally takes 30-90 seconds.
echo When ready, open http://127.0.0.1:3080
echo.

call npx --yes ^
  --package @deepseek-ai/dsh@0.1.0-rc.6 ^
  --package @deepseek-ai/cordis-plugin-group@1.0.1 ^
  --package @deepseek-ai/dsh-anonymous-user-id@0.1.0-rc.6 ^
  --package @deepseek-ai/dsh-atomic-write@0.1.0-rc.6 ^
  --package @deepseek-ai/dsh-bash-local@0.1.0-rc.6 ^
  --package @deepseek-ai/dsh-code-runtime@0.1.0-rc.6 ^
  --package @deepseek-ai/dsh-compaction@0.1.0-rc.6 ^
  --package @deepseek-ai/dsh-fs@0.1.0-rc.6 ^
  --package @deepseek-ai/dsh-invariants@0.1.0-rc.6 ^
  --package @deepseek-ai/dsh-output-retention@0.1.0-rc.6 ^
  --package @deepseek-ai/dsh-sandbox@0.1.0-rc.6 ^
  --package @deepseek-ai/dsh-scope@0.1.0-rc.6 ^
  --package @deepseek-ai/dsh-session-telemetry@0.1.0-rc.6 ^
  --package @deepseek-ai/dsh-session-title-llm@0.1.0-rc.6 ^
  --package @deepseek-ai/dsh-shell@0.1.0-rc.6 ^
  --package @deepseek-ai/dsh-spill@0.1.0-rc.6 ^
  --package @deepseek-ai/dsh-subagent-in-process-driver@0.1.0-rc.6 ^
  --package @deepseek-ai/dsh-subprocess@0.1.0-rc.6 ^
  --package @deepseek-ai/dsh-timeout@0.1.0-rc.6 ^
  --package @deepseek-ai/dsh-workflow@0.1.0-rc.6 ^
  dsh web %*

endlocal
