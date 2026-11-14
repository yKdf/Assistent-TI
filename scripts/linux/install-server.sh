#!/usr/bin/env bash
# Debian 12+/Ubuntu 24.04+. Execute no servidor de destino, não nos computadores gerenciados.
set -euo pipefail
umask 077
domain=''
usage() {
  echo 'Uso: sudo bash scripts/linux/install-server.sh [dominio] [--http] [--bind IP:PORTA] [--public-url URL] [--print-config]'
  echo '  --http          HTTP puro em 0.0.0.0:80, sem SSL ou proxy; domínio não é obrigatório.'
  echo '  --bind IP:PORTA  Endereço alternativo no modo --http (IPv6 entre colchetes).'
  echo '  --public-url    Origem pública opcional no modo --http; não instala SSL nem proxy.'
  echo '  --print-config  Exibe a configuração sem instalar ou alterar o sistema.'
}
http_only=false
print_config=false
bind=''
public_url=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --http) http_only=true; shift ;;
    --help|-h) usage; exit 0 ;;
    --bind) [[ $# -ge 2 ]] || { usage >&2; exit 1; }; bind="$2"; shift 2 ;;
    --public-url) [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 1; }; public_url="$2"; shift 2 ;;
    --print-config) print_config=true; shift ;;
    --*) usage >&2; exit 1 ;;
    *) [[ -z "$domain" ]] || { usage >&2; exit 1; }; domain="$1"; shift ;;
  esac
done
if [[ -n "$domain" ]]; then
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$domain" != *..* ]] || { usage >&2; exit 1; }
fi
if $http_only; then
  bind="${bind:-0.0.0.0:80}"
  if [[ -z "$public_url" && -n "$domain" ]]; then public_url="http://$domain"; fi
else
  [[ -n "$domain" && "$domain" == *.* ]] || { usage >&2; exit 1; }
  [[ -z "$bind" && -z "$public_url" ]] || { echo '--bind e --public-url requerem --http.' >&2; exit 1; }
  bind='127.0.0.1:8080'
  public_url="https://$domain"
fi
[[ -z "$public_url" || "$public_url" =~ ^https?://([A-Za-z0-9.-]+|\[[0-9a-fA-F:]+\])(:[0-9]{1,5})?/?$ ]] || { echo 'URL pública inválida; informe somente a origem HTTP/HTTPS.' >&2; exit 1; }
[[ "$bind" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|\[[0-9a-fA-F:]+\]):[0-9]{1,5}$ ]] || { echo 'Use IP:porta; IPv6 deve estar entre colchetes.' >&2; exit 1; }
port="${bind##*:}"
port=$((10#$port))
[[ $port -ge 1 && $port -le 65535 ]] || { echo 'Porta fora do intervalo 1-65535.' >&2; exit 1; }
bind="${bind%:*}:$port"
health_bind="$bind"
[[ "$bind" != "0.0.0.0:$port" ]] || health_bind="127.0.0.1:$port"
[[ "$bind" != "[::]:$port" ]] || health_bind="[::1]:$port"

render_environment() {
  printf 'ASSIST_PUBLIC_URL=%s\nASSIST_BIND=%s\n' "$public_url" "$bind"
}
render_unit() {
  cat <<'EOF'
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
EnvironmentFile=/etc/assist-ti/server.env
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/assist-ti
UMask=0077
EOF
  if [[ $port -lt 1024 ]]; then
    printf 'AmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE\n'
  fi
  printf '[Install]\nWantedBy=multi-user.target\n'
}
if $print_config; then
  printf '# /etc/assist-ti/server.env (HTTP sem TLS: %s)\n' "$http_only"
  render_environment
  printf '\n# /etc/systemd/system/assist-ti.service\n'
  render_unit
  exit 0
fi
[[ $EUID -eq 0 ]] || { echo 'Execute com sudo.' >&2; exit 1; }
if $http_only && [[ -f /etc/caddy/assist-ti.caddyfile ]] && systemctl is-active --quiet caddy; then
  echo 'A instalação anterior usa Caddy. Veja docs/http-server.md para liberar a porta antes de migrar.' >&2
  exit 1
fi
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v apt-get >/dev/null || { echo 'Instalador suporta Debian/Ubuntu com systemd.' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
packages=(ca-certificates curl build-essential pkg-config libssl-dev)
if ! $http_only; then packages+=(caddy); fi
echo 'Instalando dependências; se o dpkg estiver ocupado, aguardaremos até 10 minutos.'
apt-get -o DPkg::Lock::Timeout=600 install -y "${packages[@]}"
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
render_environment > /etc/assist-ti/server.env
chown root:assistti /etc/assist-ti/server.env
chmod 640 /etc/assist-ti/server.env
render_unit > /etc/systemd/system/assist-ti.service
chmod 644 /etc/systemd/system/assist-ti.service
if ! $http_only; then
  cat > /etc/caddy/assist-ti.caddyfile <<EOF
$domain {
    encode zstd gzip
    header Strict-Transport-Security "max-age=31536000"
    reverse_proxy 127.0.0.1:8080
}
EOF
  chmod 644 /etc/caddy/assist-ti.caddyfile
  if ! grep -Fxq 'import /etc/caddy/assist-ti.caddyfile' /etc/caddy/Caddyfile; then
    cp -p /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.backup.$(date +%s)"
    printf '\nimport /etc/caddy/assist-ti.caddyfile\n' >> /etc/caddy/Caddyfile
  fi
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
fi
systemctl daemon-reload
systemctl enable assist-ti
systemctl restart assist-ti
if ! $http_only; then
  systemctl enable caddy
  systemctl reload-or-restart caddy
fi
for attempt in {1..15}; do
  if curl -fsS "http://$health_bind/health" >/dev/null; then break; fi
  sleep 1
done
curl -fsS "http://$health_bind/health"
if $http_only; then
  printf '\nServidor HTTP em %s, sem SSL e sem proxy integrado. Acesse http://IP-DO-SERVIDOR:%s/\n' "$bind" "$port"
else
  printf '\nServidor instalado. Painel: %s\nDNS deve apontar para este servidor; libere TCP 80/443 para emissão do certificado e acesso.\n' "$public_url"
fi
