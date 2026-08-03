#!/usr/bin/env bash
# Local Jumper smoke with optional leapfrog reporter output.
#
# Examples:
#   ./run_local.sh
#   ./run_local.sh --report:report.log --report-mode:events
#   ./run_local.sh --bots:4 --max-ticks:900 --report:- --report-mode:events
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

bots=8
max_ticks=1800
seed=1
port=8080
report=""
report_mode="events"
global=0
extra=()

usage() {
  cat <<'EOF'
Usage: ./run_local.sh [options]

  --bots:N            Number of leapfrog bots (default 8)
  --max-ticks:N       End the episode after N ticks (default 1800)
  --seed:N            Game seed (default 1)
  --port:N            Server port (default 8080)
  --report:PATH       Reporter output path, or "-" for stdout
  --report-mode:MODE  all | changes | events (default events)
  --global            Open the global HTML spectator
  -h, --help          Show this help
EOF
}

for arg in "$@"; do
  case "$arg" in
    --bots:*) bots="${arg#--bots:}" ;;
    --max-ticks:*) max_ticks="${arg#--max-ticks:}" ;;
    --seed:*) seed="${arg#--seed:}" ;;
    --port:*) port="${arg#--port:}" ;;
    --report:*) report="${arg#--report:}" ;;
    --report-mode:*) report_mode="${arg#--report-mode:}" ;;
    --global) global=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      extra+=("$arg")
      ;;
  esac
done

echo "Building jumper and leapfrog..."
nim c --path:src --outdir:out src/jumper.nim >/dev/null
nim c --path:src --outdir:out players/leapfrog/leapfrog.nim >/dev/null

server_log="$(mktemp -t jumper-server.XXXXXX)"
cleanup() {
  if [[ -n "${server_pid:-}" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  for pid in "${bot_pids[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -f "$server_log"
}
trap cleanup EXIT

config="{\"seed\":${seed},\"maxTicks\":${max_ticks},\"maxGames\":1,\"num_agents\":${bots}}"
echo "Starting jumper on port ${port} (maxTicks=${max_ticks})..."
./out/jumper --host:127.0.0.1 --port:"$port" --config:"$config" \
  >"$server_log" 2>&1 &
server_pid=$!

# Wait until the health endpoint answers.
for _ in $(seq 1 50); do
  if curl -sf "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "Server exited early:"
    cat "$server_log"
    exit 1
  fi
  sleep 0.1
done

if [[ "$global" -eq 1 ]]; then
  open "http://127.0.0.1:${port}/client/global" 2>/dev/null || true
fi

bot_pids=()
echo "Launching ${bots} leapfrog bots..."
for i in $(seq 1 "$bots"); do
  name="lf$((i - 1))"
  args=(
    --address:127.0.0.1
    --port:"$port"
    --name:"$name"
    --max-steps:"$max_ticks"
  )
  # Attach the reporter to the first bot only.
  if [[ "$i" -eq 1 && -n "$report" ]]; then
    args+=(--report:"$report" --report-mode:"$report_mode")
    echo "Reporter on ${name}: --report:${report} --report-mode:${report_mode}"
  fi
  ./out/leapfrog "${args[@]}" >/dev/null 2>&1 &
  bot_pids+=("$!")
done

# Wait for the server episode to finish.
while kill -0 "$server_pid" 2>/dev/null; do
  sleep 0.5
done
wait "$server_pid" || true

echo "Episode finished."
if [[ -n "$report" && "$report" != "-" && -f "$report" ]]; then
  lines=$(wc -l <"$report" | tr -d ' ')
  echo "Report wrote ${lines} lines to ${report}"
fi
