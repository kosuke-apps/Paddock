#!/bin/bash
# Records what a Paddock-started ollama server connects to over a long run, to check that it talks to nothing
# but 127.0.0.1, including when its model-recommendation refresh comes due (about every four hours).
#
#   tools/long-run.sh <new record directory> --until-exit
#       Runs until the server stops, for days if need be. The Mac sleeps as usual; sleep shows up as GAP lines.
#       Sockets are sampled every 200 ms. Nothing is sent to the server: the apps that use it are the load.
#   tools/long-run.sh <new record directory> --hours <n>
#       Runs until the refresh the server has scheduled (read from its log) plus 30 minutes, and at least n hours,
#       keeping the Mac awake. Sockets are sampled every 50 ms, and two requests start a model runner.
#
# Turn the server on in Paddock first. Records:
#   conditions.txt   what ran, when, and how
#   netwatch.txt     every socket of the server and its child processes (tools/netwatch.swift)
#   dns.log          name lookups that ollama or llama-server asked the system resolver for (mDNSResponder)
#   requests.log     the requests sent during a --hours run
#   ollama-serve.log the server's own output, copied at the end if the script is still running then
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

usage="usage: tools/long-run.sh <new record directory> --until-exit | --hours <n>"
dir=${1:?$usage}
case "${2:-}" in
  --until-exit) mode=until-exit; interval=200 ;;
  --hours) mode=hours; interval=50; min_hours=${3:?$usage} ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
if [ -e "$dir" ]; then
  echo "error: $dir exists; records are never overwritten" >&2
  exit 1
fi

# The server must be the one Paddock started: the listener on 11434 whose parent is Paddock.
serve=$(lsof -t -nP -iTCP:11434 -sTCP:LISTEN | head -1)
[ -n "$serve" ] || { echo "error: nothing listens on 11434; turn the server on in Paddock" >&2; exit 1; }
parent=$(ps -o ppid= -p "$serve" | tr -d ' ')
case "$(ps -o comm= -p "$parent")" in
  */Paddock) ;;
  *) echo "error: pid $serve was not started by Paddock (parent: $(ps -o comm= -p "$parent"))" >&2; exit 1 ;;
esac

log=$(ls -t "$HOME"/Library/Logs/Paddock/ollama-serve-*.log | head -1)
wait_go=$(grep -o 'model recommendations cache sleep scheduled" wait=[0-9hms.]*' "$log" | tail -1 | sed 's/.*wait=//')
wait_s=$(python3 -c "
import re, sys
parts = dict((u, float(v)) for v, u in re.findall(r'([0-9.]+)(h|m|s)', sys.argv[1]))
print(int(parts.get('h', 0) * 3600 + parts.get('m', 0) * 60 + parts.get('s', 0)))" "$wait_go")
started_s=$(ps -o etime= -p "$serve" | awk -F'[-:]' '{ n = NF; s = $n + 60 * $(n-1); if (n >= 3) s += 3600 * $(n-2); if (n == 4) s += 86400 * $1; print s }')
due_s=$(( wait_s - started_s ))  # seconds from now until the first refresh is due
if [ "$mode" = hours ]; then
  duration=$(( due_s + 1800 ))
  (( duration < min_hours * 3600 )) && duration=$(( min_hours * 3600 ))
fi

mkdir -p "$dir"
mkdir -p build
xcrun swiftc -O -swift-version 6 -o build/netwatch tools/netwatch.swift

{
  echo "started:          $(date '+%Y-%m-%dT%H:%M:%S%z')"
  if [ "$mode" = hours ]; then
    echo "planned duration: ${duration} s ($(( duration / 3600 )) h $(( duration % 3600 / 60 )) min), Mac kept awake"
  else
    echo "planned duration: until the server stops; the Mac sleeps as usual"
  fi
  echo "refresh due:      in ${due_s} s (server log: wait=${wait_go} after its start)"
  echo "server:           pid $serve, parent pid $parent ($(ps -o comm= -p "$parent"))"
  echo "server command:   $(ps -o command= -p "$serve")"
  echo "server OLLAMA_*:  $(ps -E -o command= -p "$serve" | tr ' ' '\n' | grep '^OLLAMA_' | tr '\n' ' ')"
  echo "server log:       $log"
  echo "ollama:           $(ollama --version 2>&1 | tail -1)"
  echo "macOS:            $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(sysctl -n hw.model)"
  echo "Paddock commit:   $(git rev-parse --short HEAD)$(git diff --quiet || echo ' (with uncommitted changes)')"
  echo "power:            $(pmset -g batt | head -1)"
  echo "sampling:         every ${interval} ms; sockets open for less than about ${interval} ms can be missed"
} > "$dir/conditions.txt"

/usr/bin/log stream --style compact --predicate \
  'process == "mDNSResponder" AND (eventMessage CONTAINS "(ollama)" OR eventMessage CONTAINS "(llama-server)")' \
  > "$dir/dns.log" 2>&1 &
dns=$!

if [ "$mode" = hours ]; then
  build/netwatch --pid "$serve" --out "$dir/netwatch.txt" --interval-ms "$interval" --duration-s "$duration" \
    --watch-file "$HOME/.ollama/cache/model-recommendations.json" &
  watch=$!
  caffeinate -i -w "$watch" &
else
  build/netwatch --pid "$serve" --out "$dir/netwatch.txt" --interval-ms "$interval" \
    --watch-file "$HOME/.ollama/cache/model-recommendations.json" &
  watch=$!
fi

request() {
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') request: $1" >> "$dir/requests.log"
  curl -s --max-time 300 http://127.0.0.1:11434/api/generate \
    -d '{"model":"gemma3:4b","prompt":"Reply with the single word OK.","stream":false,"options":{"num_predict":5}}' \
    | head -c 300 >> "$dir/requests.log" || true
  echo >> "$dir/requests.log"
}
if [ "$mode" = hours ]; then
  ( sleep 60; request "one minute after the start" ) &
  ( sleep $(( due_s + 600 )); request "ten minutes after the refresh was due" ) &
fi

wait "$watch" || true
kill "$dns" 2>/dev/null || true
cp "$log" "$dir/ollama-serve.log"
echo "ended:            $(date '+%Y-%m-%dT%H:%M:%S%z')" >> "$dir/conditions.txt"
echo "power at end:     $(pmset -g batt | head -1)" >> "$dir/conditions.txt"
grep -E ' (END|FLAG) ' "$dir/netwatch.txt" | head -20
