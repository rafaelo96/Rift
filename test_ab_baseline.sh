#!/bin/bash
# Rift A/B Visual Test Script
# Ejecutar desde /Users/rafael/Documents/Rift
# Requiere: grabación de pantalla del usuario durante cada corrida

set -e

VIDEO="/Users/rafael/Downloads/Avatar.Aang.el.ultimo.maestro.del.aire.2026.WEB-DL.4k.HDR-Dual-Lat.mkv"
LOGDIR="/tmp/rift_ab_test"
mkdir -p "$LOGDIR"

echo "=== RIFT A/B TEST ==="
echo "Video: $VIDEO"
echo "Logs: $LOGDIR"
echo ""

# Clean previous logs
rm -f /tmp/rift_cadence.log /tmp/rift_diag.log /tmp/rift_timing.csv /tmp/rift.log

# --- TEST 1: motion4x (baseline) ---
echo "=== TEST 1: motion4x baseline ==="
echo "INSTRUCCIONES:"
echo "1. Ejecuta esta ventana de terminal"
echo "2. Inicia grabación de pantalla (Cmd+Shift+5 → Grabar ventana)"
echo "3. Espera a que Rift abra y reproduzca ~90 segundos"
echo "4. Detén la grabación y guárdala como: /Users/rafael/Documents/Rift/baseline_motion4x.mov"
echo ""
echo "Presiona Enter para lanzar Rift con motion4x..."
read -r

RIFT_AUTO_OPEN="$VIDEO" RIFT_AUTO_MODE=motion4x swift run Rift &
RIFT_PID=$!
echo "Rift PID: $RIFT_PID"

echo "Esperando 95 segundos de reproducción..."
sleep 95

kill $RIFT_PID 2>/dev/null || true
wait $RIFT_PID 2>/dev/null || true
echo "Rift terminado."

# Save logs
cp /tmp/rift_cadence.log "$LOGDIR/cadence_motion4x.log" 2>/dev/null || echo "No se generó rift_cadence.log"
cp /tmp/rift_diag.log "$LOGDIR/diag_motion4x.log" 2>/dev/null || echo "No se generó rift_diag.log"
cp /tmp/rift_timing.csv "$LOGDIR/timing_motion4x.csv" 2>/dev/null || echo "No se generó rift_timing.csv"
cp /tmp/rift.log "$LOGDIR/rift_motion4x.log" 2>/dev/null || echo "No se generó rift.log"

echo ""
echo "=== TEST 1 COMPLETADO ==="
echo "Logs guardados en $LOGDIR"
echo ""

# --- TEST 2: native (disabled) ---
echo "=== TEST 2: native (Frame+ Off) ==="
echo "INSTRUCCIONES:"
echo "1. Inicia nueva grabación de pantalla"
echo "2. Espera ~90 segundos"
echo "3. Detén la grabación y guárdala como: /Users/rafael/Documents/Rift/baseline_native.mov"
echo ""
echo "Presiona Enter para lanzar Rift sin interpolación..."
read -r

# Clean logs for second run
rm -f /tmp/rift_cadence.log /tmp/rift_diag.log /tmp/rift_timing.csv /tmp/rift.log

RIFT_AUTO_OPEN="$VIDEO" RIFT_AUTO_MODE=disabled swift run Rift &
RIFT_PID=$!
echo "Rift PID: $RIFT_PID"

echo "Esperando 95 segundos de reproducción..."
sleep 95

kill $RIFT_PID 2>/dev/null || true
wait $RIFT_PID 2>/dev/null || true
echo "Rift terminado."

# Save logs
cp /tmp/rift_cadence.log "$LOGDIR/cadence_native.log" 2>/dev/null || echo "No se generó rift_cadence.log"
cp /tmp/rift_diag.log "$LOGDIR/diag_native.log" 2>/dev/null || echo "No se generó rift_diag.log"
cp /tmp/rift_timing.csv "$LOGDIR/timing_native.csv" 2>/dev/null || echo "No se generó rift_timing.csv"
cp /tmp/rift.log "$LOGDIR/rift_native.log" 2>/dev/null || echo "No se generó rift.log"

echo ""
echo "=== TEST 2 COMPLETADO ==="
echo ""
echo "=== RESUMEN ==="
echo "Archivos generados:"
ls -la "$LOGDIR/"
echo ""
echo "Grabaciones esperadas:"
echo "  /Users/rafael/Documents/Rift/baseline_motion4x.mov"
echo "  /Users/rafael/Documents/Rift/baseline_native.mov"
