#!/usr/bin/env bash
# ============================================================
#  start.sh -- Lanzador del Trading Chart.
#  Arranca el servidor Mojolicious y abre el navegador por
#  defecto del sistema. Detener: Ctrl+C en esta ventana.
# ============================================================

URL="http://localhost:3000"

cd "$(dirname "$0")/backend" || { echo "No encuentro la carpeta backend"; exit 1; }

abrir_navegador() {
  local url="$1"

  # 1) Esperar (hasta ~15s) a que el servidor acepte conexiones
  for _ in $(seq 1 30); do
    (exec 3<>/dev/tcp/127.0.0.1/3000) 2>/dev/null && break
    sleep 0.5
  done

  # 2) Probar abridores en orden; usar el primero que exista Y funcione.
  #    gio/xdg-open respetan el navegador POR DEFECTO del sistema;
  #    el resto son respaldos por si la integracion de escritorio falla.
  for opener in "gio open" xdg-open gnome-open "$BROWSER" \
                google-chrome google-chrome-stable chromium chromium-browser \
                firefox microsoft-edge brave-browser; do
    [ -z "$opener" ] && continue
    local bin="${opener%% *}"
    command -v "$bin" >/dev/null 2>&1 || continue
    if $opener "$url" >/dev/null 2>&1; then
      echo ">> Navegador abierto con: $opener"
      return 0
    fi
  done

  echo ">> No pude abrir el navegador automaticamente. Abre manualmente: $url"
  return 1
}

echo "Iniciando Trading Chart en $URL ..."
echo "(Para detenerlo: Ctrl+C)"

abrir_navegador "$URL" &

exec perl app.pl daemon -l "http://*:3000"
