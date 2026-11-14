#!/usr/bin/env bash
# Rendering only: no packages, services, SSL or proxy are installed.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
installer="$root/scripts/linux/install-server.sh"
plain="$(bash "$installer" --http --print-config)"
[[ "$plain" == *'ASSIST_BIND=0.0.0.0:80'* ]]
[[ "$plain" == *$'ASSIST_PUBLIC_URL=\n'* ]]
[[ "$plain" == *'AmbientCapabilities=CAP_NET_BIND_SERVICE'* ]]
[[ "$plain" == *'User=assistti'* && "$plain" == *'NoNewPrivileges=true'* ]]
domain="$(bash "$installer" ti.example.com --http --print-config)"
[[ "$domain" == *'ASSIST_PUBLIC_URL=http://ti.example.com'* ]]
external="$(bash "$installer" --http --public-url https://ti.example.com --print-config)"
[[ "$external" == *'ASSIST_PUBLIC_URL=https://ti.example.com'* && "$external" == *'ASSIST_BIND=0.0.0.0:80'* ]]
local_only="$(bash "$installer" --http --bind 127.0.0.1:8080 --print-config)"
[[ "$local_only" == *'ASSIST_BIND=127.0.0.1:8080'* && "$local_only" != *'AmbientCapabilities='* ]]
ipv6="$(bash "$installer" --http --bind '[::]:80' --print-config)"
[[ "$ipv6" == *'ASSIST_BIND=[::]:80'* ]]
default="$(bash "$installer" ti.example.com --print-config)"
[[ "$default" == *'ASSIST_BIND=127.0.0.1:8080'* && "$default" == *'HTTP sem TLS: false'* ]]
for invalid in '0.0.0.0:0' '0.0.0.0:65536' 'hostname:80' '0.0.0.0:80/evil'; do
  if bash "$installer" --http --bind "$invalid" --print-config >/dev/null 2>&1; then exit 1; fi
done
for invalid in 'ftp://example.com' 'https://user:password@example.com' 'https://example.com/path'; do
  if bash "$installer" --http --public-url "$invalid" --print-config >/dev/null 2>&1; then exit 1; fi
done
if bash "$installer" --print-config >/dev/null 2>&1; then exit 1; fi
if bash "$installer" ti.example.com --bind 127.0.0.1:80 --print-config >/dev/null 2>&1; then exit 1; fi
echo 'Server configuration tests passed: HTTP without domain/SSL, port 80, IPv6, capabilities and validation.'
