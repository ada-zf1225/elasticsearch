#!/usr/bin/env bash
#
# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. Licensed under the "Elastic License
# 2.0", the "GNU Affero General Public License v3.0 only", and the "Server Side
# Public License, v 1"; you may not use this file except in compliance with, at
# your election, the "Elastic License 2.0", the "GNU Affero General Public
# License v3.0 only", or the "Server Side Public License, v 1".
#

set -euo pipefail
shopt -s nullglob

usage() {
    cat <<'EOF'
Usage:
  dev-tools/perf-compare/run.sh [options]

Options:
  --label <name>        Override machine label in result filenames.
  --heap <size>         Heap passed to Elasticsearch during runtime benchmark. Default: 2g
  --docs <count>        Number of documents to index in the runtime benchmark. Default: 10000
  --search-runs <count> Number of search requests in the runtime benchmark. Default: 100
  --port <port>         HTTP port for the temporary Elasticsearch node. Default: 19200
  --skip-build          Skip the timed `clean localDistro` build benchmark.
  --skip-runtime        Skip the distro startup and HTTP benchmark.
  -h, --help            Show this help text.

The script writes Markdown and JSON results into dev-tools/perf-compare/results/.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
WORK_DIR="${SCRIPT_DIR}/work"

LABEL="$(hostname -s 2>/dev/null || hostname || echo unknown-host)"
HEAP="2g"
DOCS=10000
SEARCH_RUNS=100
PORT=19200
SKIP_BUILD=0
SKIP_RUNTIME=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label)
            LABEL="$2"
            shift 2
            ;;
        --heap)
            HEAP="$2"
            shift 2
            ;;
        --docs)
            DOCS="$2"
            shift 2
            ;;
        --search-runs)
            SEARCH_RUNS="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --skip-runtime)
            SKIP_RUNTIME=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

mkdir -p "${RESULTS_DIR}" "${WORK_DIR}"

sanitize_label() {
    printf '%s' "$1" | tr '[:space:]/:' '-' | tr -cd '[:alnum:]_.-'
}

now_ms() {
    perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000'
}

time_command() {
    local __result_var="$1"
    shift
    local start_ms end_ms
    start_ms="$(now_ms)"
    "$@"
    end_ms="$(now_ms)"
    printf -v "${__result_var}" '%s' "$((end_ms - start_ms))"
}

json_escape() {
    printf '%s' "$1" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

json_number_or_null() {
    if [[ -n "${1:-}" ]]; then
        printf '%s' "$1"
    else
        printf 'null'
    fi
}

detect_cpu_model() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown"
    elif [[ -r /proc/cpuinfo ]]; then
        awk -F: '/model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo
    else
        uname -m
    fi
}

detect_local_distro_path() {
    local local_dir candidate
    local_dir="${REPO_ROOT}/build/distribution/local"
    [[ -d "${local_dir}" ]] || return 0

    for candidate in "${local_dir}"/elasticsearch-*; do
        [[ -d "${candidate}" ]] || continue
        printf '%s\n' "${candidate}"
        return 0
    done
}

wait_for_http() {
    local endpoint="$1"
    local timeout_seconds="$2"
    local start_ms end_ms attempt
    start_ms="$(now_ms)"
    for attempt in $(seq 1 "${timeout_seconds}"); do
        if curl -fsS "${endpoint}" >/dev/null 2>&1; then
            end_ms="$(now_ms)"
            STARTUP_MS="$((end_ms - start_ms))"
            return 0
        fi
        sleep 1
    done
    return 1
}

cleanup() {
    if [[ -n "${SERVER_PID:-}" ]] && kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
        kill "${SERVER_PID}" >/dev/null 2>&1 || true
        wait "${SERVER_PID}" >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT

SAFE_LABEL="$(sanitize_label "${LABEL}")"
RUN_ID="${SAFE_LABEL}-$(date -u '+%Y%m%dT%H%M%SZ')"
RUN_ROOT="${WORK_DIR}/${RUN_ID}"
RESULT_JSON="${RESULTS_DIR}/${RUN_ID}.json"
RESULT_MD="${RESULTS_DIR}/${RUN_ID}.md"
DISTRO_SOURCE_PATH=""
SERVER_PID=""

mkdir -p "${RUN_ROOT}"

cd "${REPO_ROOT}"

if ! command -v java >/dev/null 2>&1; then
    echo "java is not available on PATH." >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required for the runtime benchmark." >&2
    exit 1
fi

GIT_COMMIT="$(git rev-parse --short HEAD)"
GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
JAVA_VERSION="$(java -version 2>&1 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/ $//')"
OS_NAME="$(uname -s)"
OS_VERSION="$(uname -r)"
OS_ARCH="$(uname -m)"
CPU_MODEL="$(detect_cpu_model)"

WARMUP_MS=""
BUILD_MS=""
STARTUP_MS=""
BULK_MS=""
SEARCH_MS=""

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
    echo "Warming Gradle with --no-daemon help..."
    time_command WARMUP_MS ./gradlew --no-daemon help
    echo "Running timed clean localDistro..."
    time_command BUILD_MS ./gradlew --no-daemon clean localDistro
fi

if [[ "${SKIP_RUNTIME}" -eq 0 ]]; then
    DISTRO_SOURCE_PATH="$(detect_local_distro_path)"
    if [[ -z "${DISTRO_SOURCE_PATH}" ]]; then
        echo "Could not locate local distro under build/distribution/local. Run localDistro first." >&2
        exit 1
    fi

    INSTALL_DIR="${RUN_ROOT}/install"
    BULK_FILE="${RUN_ROOT}/bench.ndjson"
    PID_FILE="${RUN_ROOT}/elasticsearch.pid"
    mkdir -p "${INSTALL_DIR}"

    echo "Copying local distro from ${DISTRO_SOURCE_PATH}..."
    cp -R "${DISTRO_SOURCE_PATH}" "${INSTALL_DIR}/"
    ES_HOME="${INSTALL_DIR}/$(basename "${DISTRO_SOURCE_PATH}")"
    if [[ -z "${ES_HOME}" ]]; then
        echo "Could not locate extracted Elasticsearch home." >&2
        exit 1
    fi

    echo "Starting Elasticsearch from distribution..."
    ES_JAVA_OPTS="-Xms${HEAP} -Xmx${HEAP}" \
        "${ES_HOME}/bin/elasticsearch" \
        -d \
        -p "${PID_FILE}" \
        -E xpack.security.enabled=false \
        -E discovery.type=single-node \
        -E network.host=127.0.0.1 \
        -E http.port="${PORT}" \
        -E path.data="${RUN_ROOT}/data" \
        -E path.logs="${RUN_ROOT}/logs"

    if [[ ! -s "${PID_FILE}" ]]; then
        echo "Elasticsearch did not write a PID file." >&2
        exit 1
    fi
    SERVER_PID="$(cat "${PID_FILE}")"

    if ! wait_for_http "http://127.0.0.1:${PORT}" 180; then
        echo "Elasticsearch did not become ready on port ${PORT}." >&2
        if [[ -d "${RUN_ROOT}/logs" ]]; then
            for log_file in "${RUN_ROOT}/logs"/*; do
                [[ -f "${log_file}" ]] || continue
                echo "==== ${log_file} ===="
                sed -n '1,160p' "${log_file}"
            done
        fi
        exit 1
    fi

    echo "Preparing deterministic benchmark data..."
    : > "${BULK_FILE}"
    for ((i = 1; i <= DOCS; i++)); do
        printf '{"index":{"_index":"bench"}}\n{"id":%d,"name":"doc-%d","group":"g%d","text":"quick brown fox jumps over the lazy dog"}\n' \
            "${i}" "${i}" "$((i % 10))" >> "${BULK_FILE}"
    done

    curl -sS -o /dev/null -X DELETE "http://127.0.0.1:${PORT}/bench" || true
    curl -fsS \
        -H 'Content-Type: application/json' \
        -X PUT "http://127.0.0.1:${PORT}/bench" \
        -d '{"settings":{"number_of_shards":1,"number_of_replicas":0}}' >/dev/null

    echo "Running bulk benchmark..."
    time_command BULK_MS \
        curl -fsS \
        -H 'Content-Type: application/x-ndjson' \
        -X POST "http://127.0.0.1:${PORT}/_bulk?refresh=true" \
        --data-binary @"${BULK_FILE}" >/dev/null

    QUERY='{"query":{"match":{"text":"quick brown fox"}}}'
    curl -fsS \
        -H 'Content-Type: application/json' \
        -X POST "http://127.0.0.1:${PORT}/bench/_search" \
        -d "${QUERY}" >/dev/null

    run_searches() {
        local search_index
        for ((search_index = 1; search_index <= SEARCH_RUNS; search_index++)); do
            curl -fsS \
                -H 'Content-Type: application/json' \
                -X POST "http://127.0.0.1:${PORT}/bench/_search" \
                -d "${QUERY}" >/dev/null
        done
    }

    echo "Running search benchmark..."
    time_command SEARCH_MS run_searches
fi

cat > "${RESULT_JSON}" <<EOF
{
  "run_id": "$(json_escape "${RUN_ID}")",
  "label": "$(json_escape "${LABEL}")",
  "timestamp_utc": "$(json_escape "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")",
  "git_commit": "$(json_escape "${GIT_COMMIT}")",
  "git_branch": "$(json_escape "${GIT_BRANCH}")",
  "java_version": "$(json_escape "${JAVA_VERSION}")",
  "os_name": "$(json_escape "${OS_NAME}")",
  "os_version": "$(json_escape "${OS_VERSION}")",
  "os_arch": "$(json_escape "${OS_ARCH}")",
  "cpu_model": "$(json_escape "${CPU_MODEL}")",
  "heap": "$(json_escape "${HEAP}")",
  "docs": ${DOCS},
  "search_runs": ${SEARCH_RUNS},
  "build": {
    "warmup_help_ms": $(json_number_or_null "${WARMUP_MS}"),
    "clean_local_distro_ms": $(json_number_or_null "${BUILD_MS}")
  },
  "runtime": {
    "distribution_source_path": "$(json_escape "${DISTRO_SOURCE_PATH}")",
    "http_port": ${PORT},
    "startup_ms": $(json_number_or_null "${STARTUP_MS}"),
    "bulk_ms": $(json_number_or_null "${BULK_MS}"),
    "search_ms": $(json_number_or_null "${SEARCH_MS}")
  }
}
EOF

cat > "${RESULT_MD}" <<EOF
# Elasticsearch perf run: ${RUN_ID}

- Label: ${LABEL}
- Timestamp (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')
- Git branch: ${GIT_BRANCH}
- Git commit: ${GIT_COMMIT}
- Java: ${JAVA_VERSION}
- OS: ${OS_NAME} ${OS_VERSION} (${OS_ARCH})
- CPU: ${CPU_MODEL}
- Heap: ${HEAP}
- Docs: ${DOCS}
- Search runs: ${SEARCH_RUNS}

## Build

- Warmup \`./gradlew --no-daemon help\`: ${WARMUP_MS:-skipped} ms
- Timed \`./gradlew --no-daemon clean localDistro\`: ${BUILD_MS:-skipped} ms

## Runtime

- Distribution source: ${DISTRO_SOURCE_PATH:-skipped}
- Startup to HTTP ready: ${STARTUP_MS:-skipped} ms
- Bulk indexing: ${BULK_MS:-skipped} ms
- Search loop: ${SEARCH_MS:-skipped} ms
EOF

echo "Wrote:"
echo "  ${RESULT_JSON}"
echo "  ${RESULT_MD}"
