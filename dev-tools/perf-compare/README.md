# Perf Compare Helper

This helper wraps a small, repeatable Elasticsearch comparison workload for two machines.
It is intended for local source checkouts that you sync with Git.

## What it measures

- Gradle warmup: `./gradlew --no-daemon help`
- Build benchmark: `./gradlew --no-daemon clean localDistro`
- Runtime benchmark from the built distribution:
  - startup time to HTTP ready
  - one bulk index of deterministic documents
  - a fixed number of search requests

Results are written to `dev-tools/perf-compare/results/` as both Markdown and JSON.

## Before you run it

1. Use the same commit on both machines.
2. Use the same JDK version and vendor on both machines.
3. Close other heavy processes if you want cleaner numbers.
4. Pick the same heap on both machines.

## Run on macOS or Linux

```bash
bash dev-tools/perf-compare/run.sh --label macbook --heap 2g
```

## Run on Windows PowerShell

```powershell
powershell -ExecutionPolicy Bypass -File .\dev-tools\perf-compare\run.ps1 -Label win-gaming -Heap 2g
```

## Useful options

- `--skip-build` or `-SkipBuild`: reuse an existing `localDistro` build and only run the runtime benchmark
- `--skip-runtime` or `-SkipRuntime`: measure the build only
- `--docs <count>` or `-Docs <count>`: change the bulk size
- `--search-runs <count>` or `-SearchRuns <count>`: change the number of search requests
- `--port <port>` or `-Port <port>`: use a different HTTP port if `19200` is busy

## Sync through GitHub

After a run, commit only the generated result files:

```bash
git add dev-tools/perf-compare/results/*.json dev-tools/perf-compare/results/*.md
git commit -m "Add perf results for <machine>"
git push
```

Then pull on the other machine and compare the two Markdown files side by side.
