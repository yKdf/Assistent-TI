#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Execute com sudo.' >&2; exit 1; }
source_dir="${1:?Informe a pasta da release assinada}"
dest=/var/lib/assist-ti/releases
# Publicação troca o manifesto por último; as versões anteriores ficam disponíveis para downloads em andamento.
shopt -s nullglob
files=("$source_dir"/*.exe)
[[ ${#files[@]} -gt 0 && -f "$source_dir/release.json" ]] || { echo 'Release incompleta.' >&2; exit 1; }
for file in "${files[@]}"; do
  name="$(basename -- "$file")"
  [[ "$name" =~ ^[a-f0-9]{64}\.exe$ ]] || { echo 'Nome de arquivo inválido.' >&2; exit 1; }
  actual="$(sha256sum -- "$file")"
  [[ "${actual%% *}.exe" == "$name" ]] || { echo 'Hash do arquivo não confere.' >&2; exit 1; }
  install -m 640 -o assistti -g assistti "$file" "$dest/$name.tmp"
  mv -f "$dest/$name.tmp" "$dest/$name"
done
install -m 640 -o assistti -g assistti "$source_dir/release.json" "$dest/release.json.new"
mv -f "$dest/release.json.new" "$dest/release.json"
echo 'Release publicada. Agentes com a chave correspondente verificarão a assinatura antes de atualizar.'
