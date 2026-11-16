#!/usr/bin/env bash
# sinirli COMMAND — at most 2 cores, low priority; a watchdog that kills the job if the total memory of all
# child processes exceeds SINIR_GB (default 4). (On 2026-11-14 an APK build crashed the PC.)
# Child processes are found by an environment variable tag: processes that escape into their own process group
# (detach), like Gradle/Kotlin, are measured too and killed if needed.
LIMIT_KB=$(( ${LIMIT_GB:-${SINIR_GB:-4}} * 1024 * 1024 ))
TAG="limited-$$-$RANDOM$RANDOM"
export TIPHYS_LIMITED_TAG="$TAG"
setsid taskset -c 0,1 nice -n 15 ionice -c2 -n7 "$@" &
PID=$!
tagged() {
  for e in /proc/[0-9]*/environ; do
    if grep -qaF "TIPHYS_LIMITED_TAG=$TAG" "$e" 2>/dev/null; then p=${e#/proc/}; echo "${p%/environ}"; fi
  done
}
peak=0
while kill -0 "$PID" 2>/dev/null; do
  pids=$(tagged)
  rss=0
  for p in $pids; do r=$(awk '/^VmRSS:/ {print $2}' "/proc/$p/status" 2>/dev/null); rss=$(( rss + ${r:-0} )); done
  (( rss > peak )) && peak=$rss
  if (( rss > LIMIT_KB )); then
    echo "BELLEK SINIRI AŞILDI ($((rss/1024)) MB) — iş durduruldu" >&2
    kill -9 -- -"$PID" $pids 2>/dev/null
    exit 137
  fi
  sleep 1
done
wait "$PID"; rc=$?
# Tagged processes left behind after the job ends (e.g. the Gradle daemon) are shut down.
left=$(tagged); [ -n "$left" ] && kill $left 2>/dev/null
echo "[limited] en yüksek bellek: $((peak/1024)) MB, çıkış kodu: $rc" >&2
exit $rc
