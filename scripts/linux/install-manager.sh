#!/usr/bin/env bash
set -euo pipefail
url="${1:-}"
binary="${2:-./target/release/assist-manager}"
[[ "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ || "$url" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]+)?/?$ ]] || { echo 'Uso: bash install-manager.sh https://ti.empresa.com /caminho/assist-manager' >&2; exit 1; }
dest="$HOME/.local/share/assist-ti"
install -d -m 755 "$dest" "$HOME/.local/share/applications"
install -m 755 "$binary" "$dest/assist-manager"
printf '%s' "$url" > "$dest/server-url.txt"
cat > "$HOME/.local/share/applications/assist-ti.desktop" <<EOF
[Desktop Entry]
Name=Assistente TI
Comment=Central de gerenciamento de computadores
Exec="$dest/assist-manager"
Icon=computer
Terminal=false
Type=Application
Categories=System;RemoteAccess;
EOF
printf 'Aplicativo instalado. Abra Assistente TI no menu. Requer Chromium, Edge ou Chrome.\n'
