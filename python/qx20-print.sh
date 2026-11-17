#!/bin/bash
# Joins the QX20 Wi-Fi, prints, then leaves so macOS auto-rejoins your
# usual network. Usage: ./qx20-print.sh foto.jpg [foto2.jpg ...] [--paper card --border 2]
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
IF=en0
source "$DIR/.qx20.env"

# Run the helper through the Swift interpreter: a compiled binary has no
# location permission, so macOS hides network names (SSID) from it.
wifi() { xcrun swift "$DIR/tools/wifi.swift" "$@"; }

log() { echo "[$(date +%H:%M:%S)] $*"; }
on_printer() { ipconfig getifaddr "$IF" 2>/dev/null | grep -q '^192\.168\.0\.'; }

WATCH_PID=""
watchdog() {
  # macOS may jump back to a network with internet mid-print; rejoin the QX20.
  while true; do
    sleep 2
    if ! on_printer; then
      log "macOS salió de $QX20_SSID; reconectando..."
      wifi join "$QX20_SSID" "$QX20_PASS" >/dev/null 2>&1
    fi
  done
}

cleanup() {
  if [ -n "$WATCH_PID" ]; then kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null; fi
  if on_printer; then
    log "Saliendo de $QX20_SSID..."
    wifi leave >/dev/null
  fi
  for _ in $(seq 1 40); do
    if curl -s -m 2 -o /dev/null https://www.apple.com/library/test/success.html; then
      log "De vuelta en tu red normal ($(ipconfig getifaddr $IF))."
      return
    fi
    sleep 1
  done
  log "Aún sin internet: elige tu red en el menú de Wi-Fi."
}

if ! on_printer; then
  log "Conectando a $QX20_SSID..."
  wifi join "$QX20_SSID" "$QX20_PASS" || { log "No se pudo conectar. No se imprimió nada."; cleanup; exit 1; }
fi
trap cleanup EXIT

for _ in $(seq 1 30); do on_printer && break; sleep 1; done
on_printer || { log "Sin IP de la impresora. No se imprimió nada."; exit 1; }

log "Conectado a la impresora ($(ipconfig getifaddr $IF))."
watchdog &
WATCH_PID=$!
sleep 2
"$DIR/.venv/bin/python" "$DIR/qx20.py" "$@"
RC=$?
log "Impresión terminada (código $RC)."
exit $RC
