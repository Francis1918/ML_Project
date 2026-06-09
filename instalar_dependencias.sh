#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$APP_DIR"

if ! command -v cpanm >/dev/null 2>&1; then
  echo "Falta cpanm."
  echo "En Fedora/WSL instala cpanminus con:"
  echo "  sudo dnf install perl-App-cpanminus"
  echo
  echo "Luego vuelve a ejecutar esta tarea."
  exit 1
fi

cpanm --installdeps .
