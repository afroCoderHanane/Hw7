

#!/usr/bin/env bash
# Asynchronous concurrency test for the Flash Sale service
# - Hammers GET /products/{id} and POST /products/{id}/details concurrently
# - Captures HTTP status and latency, then prints a summary
#
# Usage:
#   ./test_async.sh [-u BASE_URL] [-c CONCURRENCY] [-n ROUNDS] [-m MODE] [-p IDS]
#     BASE_URL    default: http://localhost:8080
#     CONCURRENCY default: 20
#     ROUNDS      default: 50      (each round issues tasks across IDs)
#     MODE        default: mixed   (one of: get|post|mixed)
#     IDS         default: 1,2,3   (comma-separated product IDs)
#
# Examples:
#   ./test_async.sh
#   ./test_async.sh -u http://127.0.0.1:8080 -c 50 -n 100 -m mixed -p 1,2,3
#   ./test_async.sh -m get   -c 100 -n 200
#   ./test_async.sh -m post  -c 30  -n 60  -p 2,3

set -euo pipefail

BASE_URL="http://localhost:8080"
CONCURRENCY=20
ROUNDS=50
MODE="mixed"      # get|post|mixed
IDS="1,2,3"

# --- helpers ---
usage() {
  sed -n '1,35p' "$0"
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing required tool: $1" >&2; exit 1; }
}

# Parse args
while getopts ":u:c:n:m:p:h" opt; do
  case "$opt" in
    u) BASE_URL="$OPTARG" ;;
    c) CONCURRENCY="$OPTARG" ;;
    n) ROUNDS="$OPTARG" ;;
    m) MODE="$OPTARG" ;;
    p) IDS="$OPTARG" ;;
    h|*) usage ;;
  esac
done

require curl
# jq is optional (pretty printing)
if command -v jq >/dev/null 2>&1; then HAS_JQ=1; else HAS_JQ=0; fi

# Output results file
RESULTS_DIR="${TMPDIR:-/tmp}/flash_sale_tests"
mkdir -p "$RESULTS_DIR"
OUT_CSV="$RESULTS_DIR/results_$(date +%s).csv"
echo "mode,method,id,status,latency_ms" > "$OUT_CSV"

echo "🏁 Starting async test: url=$BASE_URL, conc=$CONCURRENCY, rounds=$ROUNDS, mode=$MODE, ids=$IDS"

# Convert IDs to array
IFS=',' read -r -a ID_ARR <<< "$IDS"

# Run a single GET task
get_task() {
  local id="$1"
  local start=$(date +%s%3N)
  local http_code body
  # Use curl silent, capture status and body
  body=$(curl -sS -w "\n%{http_code}" "$BASE_URL/products/$id") || true
  http_code=$(echo "$body" | tail -n1)
  local end=$(date +%s%3N)
  local ms=$((end-start))
  echo "get,GET,$id,$http_code,$ms" >> "$OUT_CSV"

  # Optional print for failures
  if [[ "$http_code" != "200" ]]; then
    echo "GET /products/$id -> $http_code (${ms}ms)"
  fi
}

# Run a single POST task (partial details update)
post_task() {
  local id="$1"
  # Randomize values a bit to simulate traffic
  local price=$((RANDOM % 200 + 10)).$((RANDOM % 100))
  local stock=$((RANDOM % 100))
  local name="Item-$id-$RANDOM"
  local payload
  payload=$(cat <<JSON
{"price": $price, "stock": $stock, "name": "${name}"}
JSON
)
  local start=$(date +%s%3N)
  local http_code body
  body=$(curl -sS -X POST -H 'Content-Type: application/json' \
    -d "$payload" -w "\n%{http_code}" "$BASE_URL/products/$id/details") || true
  http_code=$(echo "$body" | tail -n1)
  local end=$(date +%s%3N)
  local ms=$((end-start))
  echo "post,POST,$id,$http_code,$ms" >> "$OUT_CSV"

  # 204 expected on success per server
  if [[ "$http_code" != "204" ]]; then
    echo "POST /products/$id/details -> $http_code (${ms}ms)"
    if [[ $HAS_JQ -eq 1 ]]; then echo "$body" | head -n -1 | jq . || true; else echo "$body" | head -n -1; fi
  fi
}

# Concurrency control using bash wait -n
run_with_concurrency() {
  local max_jobs="$1"; shift
  local active=0
  for cmd in "$@"; do
    eval "$cmd" &
    active=$((active+1))
    if (( active >= max_jobs )); then
      wait -n || true
      active=$((active-1))
    fi
  done
  wait || true
}

# Build command list
CMDS=()
for (( r=1; r<=ROUNDS; r++ )); do
  for id in "${ID_ARR[@]}"; do
    case "$MODE" in
      get)   CMDS+=("get_task $id") ;;
      post)  CMDS+=("post_task $id") ;;
      mixed) # 50/50 split
        if (( RANDOM % 2 )); then CMDS+=("get_task $id"); else CMDS+=("post_task $id"); fi ;;
      *) echo "❌ Unknown MODE: $MODE" >&2; exit 1 ;;
    esac
  done
done

# Execute commands with concurrency
run_with_concurrency "$CONCURRENCY" "${CMDS[@]}"

echo "✅ Completed. Results: $OUT_CSV"

# Print a quick summary
awk -F, 'NR>1 {total++; s[$4]++; sum+=$5; if($4!="200" && $4!="204") fail++} END {
  printf("Total requests: %d\n", total);
  printf("Success (200/204): %d\n", s[200]+s[204]);
  printf("Failures: %d\n", fail+0);
  if(total>0) printf("Avg latency: %.2f ms\n", sum/total);
  printf("HTTP status breakdown:\n");
  for (code in s) printf("  %s: %d\n", code, s[code]);
}' "$OUT_CSV"

# Optional: show tail of CSV
echo "--- tail $OUT_CSV ---"
tail -n 10 "$OUT_CSV" || true