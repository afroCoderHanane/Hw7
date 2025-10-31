
#!/usr/bin/env bash
# Synchronous (sequential) test runner for the Flash Sale service
# - Exercises GET /products/{id}
# - Exercises POST /products/{id}/details (partial update)
# - Validates status codes and (optionally) response JSON shape
# - Records simple latency metrics and prints a summary
#
# Usage:
#   ./test_sync.sh [-u BASE_URL] [-n ROUNDS] [-m MODE] [-p IDS] [--sleep-ms N]
#     BASE_URL default: http://localhost:8080
#     ROUNDS   default: 30        (each round iterates across all IDs)
#     MODE     default: both      (one of: get|post|both)
#     IDS      default: 1,2,3     (comma-separated product IDs)
#
# Examples:
#   ./test_sync.sh
#   ./test_sync.sh -u http://127.0.0.1:8080 -n 10 -m both -p 1,2,3
#   ./test_sync.sh -m get  -n 15
#   ./test_sync.sh -m post -n 5  -p 2

set -euo pipefail

BASE_URL="http://localhost:8080"
ROUNDS=30
MODE="both"    # get|post|both
IDS="1,2,3"
SLEEP_MS=0

usage() {
  sed -n '1,40p' "$0"
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing required tool: $1" >&2; exit 1; }
}

# Parse args
while (( "$#" )); do
  case "$1" in
    -u) BASE_URL="$2"; shift 2 ;;
    -n) ROUNDS="$2"; shift 2 ;;
    -m) MODE="$2"; shift 2 ;;
    -p) IDS="$2"; shift 2 ;;
    --sleep-ms) SLEEP_MS="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

require curl
# jq is optional (for validating/pretty-printing JSON on GET)
if command -v jq >/dev/null 2>&1; then HAS_JQ=1; else HAS_JQ=0; fi

# Results
RESULTS_DIR="${TMPDIR:-/tmp}/flash_sale_tests"
mkdir -p "$RESULTS_DIR"
OUT_CSV="$RESULTS_DIR/sync_results_$(date +%s).csv"
echo "mode,method,id,status,latency_ms" > "$OUT_CSV"

echo "▶️  Starting sync test: url=$BASE_URL, rounds=$ROUNDS, mode=$MODE, ids=$IDS, sleep_ms=$SLEEP_MS"
IFS=',' read -r -a ID_ARR <<< "$IDS"

ok=0
fail=0
sum_latency=0
count=0

do_sleep() {
  local ms="$1"
  if [[ "$ms" -gt 0 ]]; then
    # portable sleep in ms
    python3 - <<PY 2>/dev/null || true
import time
try:
    time.sleep(${ms}/1000.0)
except Exception:
    pass
PY
  fi
}

get_once() {
  local id="$1"
  local start=$(date +%s%3N)
  local body
  body=$(curl -sS -w "\n%{http_code}" "$BASE_URL/products/$id") || true
  local code=$(echo "$body" | tail -n1)
  local end=$(date +%s%3N)
  local ms=$((end-start))
  echo "get,GET,$id,$code,$ms" >> "$OUT_CSV"

  if [[ "$code" == "200" ]]; then
    ok=$((ok+1))
    if [[ $HAS_JQ -eq 1 ]]; then
      # Validate id field if possible
      got_id=$(echo "$body" | head -n -1 | jq -r '.id // empty' 2>/dev/null || true)
      if [[ -n "$got_id" && "$got_id" != "$id" ]]; then
        echo "⚠️  GET /products/$id returned mismatched id=$got_id"
      fi
    fi
  else
    fail=$((fail+1))
    echo "GET /products/$id -> $code (${ms}ms)"
  fi
  sum_latency=$((sum_latency+ms))
  count=$((count+1))
}

post_once() {
  local id="$1"
  local price=$((RANDOM % 200 + 10)).$((RANDOM % 100))
  local stock=$((RANDOM % 100))
  local name="Item-$id-$RANDOM"
  local payload
  payload=$(cat <<JSON
{"price": $price, "stock": $stock, "name": "${name}"}
JSON
)
  local start=$(date +%s%3N)
  local body
  body=$(curl -sS -X POST -H 'Content-Type: application/json' -d "$payload" -w "\n%{http_code}" "$BASE_URL/products/$id/details") || true
  local code=$(echo "$body" | tail -n1)
  local end=$(date +%s%3N)
  local ms=$((end-start))
  echo "post,POST,$id,$code,$ms" >> "$OUT_CSV"

  if [[ "$code" == "204" ]]; then
    ok=$((ok+1))
  else
    fail=$((fail+1))
    echo "POST /products/$id/details -> $code (${ms}ms)"
    # print error body if any
    echo "$body" | head -n -1 | sed 's/^/    /'
  fi
  sum_latency=$((sum_latency+ms))
  count=$((count+1))
}

for (( r=1; r<=ROUNDS; r++ )); do
  for id in "${ID_ARR[@]}"; do
    case "$MODE" in
      get)  get_once "$id" ;;
      post) post_once "$id" ;;
      both) get_once "$id"; do_sleep "$SLEEP_MS"; post_once "$id" ;;
      *) echo "❌ Unknown MODE: $MODE" >&2; exit 1 ;;
    esac
    do_sleep "$SLEEP_MS"
  done
  echo "Round $r/$ROUNDS complete"
done

avg_latency=0
if [[ $count -gt 0 ]]; then
  avg_latency=$(python3 - <<PY
print(round($sum_latency/$count,2))
PY
)
fi

echo "\n✅ Sync test complete"
echo "Results CSV: $OUT_CSV"
printf "Total requests: %d\n" "$count"
printf "Successes: %d\n" "$ok"
printf "Failures: %d\n" "$fail"
printf "Avg latency: %s ms\n" "$avg_latency"

# Status breakdown
awk -F, 'NR>1 {s[$4]++} END {print "HTTP status breakdown:"; for (k in s) printf("  %s: %d\n", k, s[k]); }' "$OUT_CSV"

# Tail CSV for a quick peek
echo "--- tail $OUT_CSV ---"
tail -n 10 "$OUT_CSV" || true