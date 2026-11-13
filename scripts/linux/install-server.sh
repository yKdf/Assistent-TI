#!/usr/bin/env bash
# Debian 12+/Ubuntu 24.04+. Execute no servidor de destino, não nos computadores gerenciados.
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'Execute com sudo.' >&2; exit 1; }
domain="${1:-}"
[[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$domain" == *.* && "$domain" != *..* ]] || { echo 'Uso: sudo bash scripts/linux/install-server.sh ti.empresa.com' >&2; exit 1; }
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v apt-get >/dev/null || { echo 'Instalador suporta Debian/Ubuntu com systemd.' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl build-essential pkg-config libssl-dev caddy
if ! id assistti >/dev/null 2>&1; then useradd --system --home-dir /var/lib/assist-ti --shell /usr/sbin/nologin assistti; fi
install -d -m 750 -o assistti -g assistti /var/lib/assist-ti /var/lib/assist-ti/releases
install -d -m 750 -o root -g assistti /etc/assist-ti
install -d -m 755 /opt/assist-ti
if [[ ! -f /etc/assist-ti/admin-password ]]; then
  read -r -s -p 'Crie a senha administrativa (mínimo 14 caracteres): ' password </dev/tty
  printf '\n'
  [[ ${#password} -ge 14 ]] || { echo 'Senha muito curta.' >&2; exit 1; }
  read -r -s -p 'Repita a senha: ' repeated </dev/tty
  printf '\n'
  [[ "$password" == "$repeated" ]] || { echo 'As senhas não coincidem.' >&2; exit 1; }
  printf '%s' "$password" > /etc/assist-ti/admin-password
  unset password repeated
  chown root:assistti /etc/assist-ti/admin-password
  chmod 640 /etc/assist-ti/admin-password
fi
# Compilação sem privilégios, em uma cópia isolada; não executa build scripts como root.
if ! id assistbuild >/dev/null 2>&1; then useradd --system --create-home --home-dir /var/cache/assist-ti-build --shell /usr/sbin/nologin assistbuild; fi
install -d -m 755 -o assistbuild -g assistbuild /var/cache/assist-ti-build/source
tar -C "$root" --exclude=target --exclude=.toolchain --exclude=.git --exclude=dist --exclude=data --exclude='*.key' --exclude='*.pem' -cf - Cargo.toml Cargo.lock crates web | tar -C /var/cache/assist-ti-build/source -xf -
chown -R assistbuild:assistbuild /var/cache/assist-ti-build/source
runuser -u assistbuild -- bash -c 'set -euo pipefail; cd /var/cache/assist-ti-build/source; export CARGO_HOME=/var/cache/assist-ti-build/cargo RUSTUP_HOME=/var/cache/assist-ti-build/rustup; if [[ ! -x "$CARGO_HOME/bin/cargo" ]]; then curl --proto "=https" --tlsv1.2 -fsS https://sh.rustup.rs -o /var/cache/assist-ti-build/rustup.sh; bash /var/cache/assist-ti-build/rustup.sh -y --profile minimal --no-modify-path; fi; export PATH="$CARGO_HOME/bin:$PATH"; cargo build --locked --release -p assist-server -p assist-release -p assist-manager'
install -m 755 /var/cache/assist-ti-build/source/target/release/assist-server /opt/assist-ti/assist-server.new
install -m 755 /var/cache/assist-ti-build/source/target/release/assist-release /opt/assist-ti/assist-release
install -m 755 /var/cache/assist-ti-build/source/target/release/assist-manager /opt/assist-ti/assist-manager
mv -f /opt/assist-ti/assist-server.new /opt/assist-ti/assist-server
cat > /etc/systemd/system/assist-ti.service <<EOF
[Unit]
Description=Assistente TI Server
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=assistti
Group=assistti
WorkingDirectory=/opt/assist-ti
ExecStart=/opt/assist-ti/assist-server
Environment=ASSIST_DATA=/var/lib/assist-ti
Environment=ASSIST_ADMIN_PASSWORD_FILE=/etc/assist-ti/admin-password
Environment=ASSIST_PUBLIC_URL=https://$domain
Environment=ASSIST_BIND=127.0.0.1:8080
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/assist-ti
UMask=0077
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/caddy/assist-ti.caddyfile <<EOF
$domain {
    encode zstd gzip
    header Strict-Transport-Security "max-age=31536000"
    reverse_proxy 127.0.0.1:8080
}
EOF
chmod 644 /etc/systemd/system/assist-ti.service /etc/caddy/assist-ti.caddyfile
if ! grep -Fxq 'import /etc/caddy/assist-ti.caddyfile' /etc/caddy/Caddyfile; then
  cp -p /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.backup.$(date +%s)"
  printf '\nimport /etc/caddy/assist-ti.caddyfile\n' >> /etc/caddy/Caddyfile
fi
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl daemon-reload
systemctl enable assist-ti caddy
systemctl restart assist-ti
systemctl reload-or-restart caddy
for attempt in {1..15}; do
  if curl -fsS http://127.0.0.1:8080/health >/dev/null; then break; fi
  sleep 1
done
curl -fsS http://127.0.0.1:8080/health
printf '\nServidor instalado. Painel: https://%s\nDNS deve apontar para este servidor; libere TCP 80/443 para emissão do certificado e acesso.\n' "$domain"
