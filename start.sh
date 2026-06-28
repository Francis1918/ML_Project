#!/usr/bin/env bash
# ============================================================
#  start.sh -- Lanzador del Trading Chart.
#  Arranca el servidor y abre el navegador por defecto, incluso
#  si el navegador estaba cerrado. Detener: Ctrl+C.
# ============================================================

URL="http://127.0.0.1:3000"

cd "$(dirname "$0")/backend" || { echo "No encuentro la carpeta backend"; exit 1; }

# Lanza un comando TOTALMENTE desacoplado del terminal/script, para que
# el navegador arranque y siga vivo aunque no estuviera abierto antes.
lanzar_desacoplado() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >/dev/null 2>&1 &
  else
    nohup "$@" >/dev/null 2>&1 &
  fi
}

abrir_navegador() {
  local url="$1"

  # 1) Esperar a que el servidor responda de verdad antes de abrir el navegador.
  #    En WSL el backend puede tardar en cargar la caché inicial de datos.
  for _ in $(seq 1 120); do
    if command -v curl >/dev/null 2>&1; then
      curl -fsS "$url/api/info" >/dev/null 2>&1 && break
    else
      (exec 3<>/dev/tcp/127.0.0.1/3000) 2>/dev/null && break
    fi
    sleep 0.5
  done

  # 2) Primer abridor disponible (gio/xdg respetan el navegador por defecto),
  #    lanzado desacoplado para que funcione el arranque en frio.
  for opener in "gio open" xdg-open gnome-open "$BROWSER" \
                google-chrome google-chrome-stable chromium chromium-browser \
                firefox microsoft-edge brave-browser; do
    [ -z "$opener" ] && continue
    local bin="${opener%% *}"
    command -v "$bin" >/dev/null 2>&1 || continue
    echo ">> Abriendo navegador con: $opener"
    lanzar_desacoplado $opener "$url"
    return 0
  done

  echo ">> No pude abrir el navegador. Abre manualmente: $url"
  return 1
}

echo "Iniciando Trading Chart en $URL ..."
echo "(Para detenerlo: Ctrl+C)"

abrir_navegador "$URL" &

exec perl app.pl daemon -l "http://*:3000"
