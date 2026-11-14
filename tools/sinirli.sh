#!/usr/bin/env bash
# sinirli KOMUT — en fazla 2 çekirdek, düşük öncelik; tüm alt süreçlerin toplam belleği
# SINIR_GB'ı (varsayılan 4) geçerse işi öldüren bekçi. (2026-11-14 APK derlemesi PC'yi çökertti.)
# Alt süreçler ortam değişkeni etiketiyle bulunur: Gradle/Kotlin gibi kendi süreç grubuna kaçan
# (ayrılan) süreçler de ölçülür ve gerekirse öldürülür.
LIMIT_KB=$(( ${SINIR_GB:-4} * 1024 * 1024 ))
TAG="sinirli-$$-$RANDOM$RANDOM"
export SINIRLI_ETIKET="$TAG"
setsid taskset -c 0,1 nice -n 15 ionice -c2 -n7 "$@" &
PID=$!
tagged() {
  for e in /proc/[0-9]*/environ; do
    if grep -qaF "SINIRLI_ETIKET=$TAG" "$e" 2>/dev/null; then p=${e#/proc/}; echo "${p%/environ}"; fi
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
# İş bittikten sonra geride kalan etiketli süreçler (ör. Gradle daemon) kapatılır.
left=$(tagged); [ -n "$left" ] && kill $left 2>/dev/null
echo "[sinirli] en yüksek bellek: $((peak/1024)) MB, çıkış kodu: $rc" >&2
exit $rc
