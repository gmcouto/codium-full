#!/usr/bin/env bash
set -euo pipefail

expected='/usr/local/go/bin:/opt/rust/cargo/bin:/config/.local/share/pnpm:/usr/local/bin:/usr/bin:/bin'
path_check() { [[ "$1" == "$expected"* ]]; }
path_check "$PATH"
path_check "$(su -s /bin/bash abc -c 'bash -i -c "printf %s \"$PATH\""' 2>/dev/null)"
path_check "$(su -s /bin/bash abc -c 'bash -l -c "printf %s \"$PATH\""' 2>/dev/null)"
command -v zoxide >/dev/null
su -s /bin/bash abc -c 'bash -i -c "type z >/dev/null && type zi >/dev/null"' >/dev/null 2>&1
[[ -f /usr/share/doc/fzf/examples/key-bindings.bash ]]
[[ -f /usr/share/doc/fzf/examples/completion.bash || -f /usr/share/bash-completion/completions/fzf ]]
su -s /bin/bash abc -c 'bash -i -c "type __fzf_select__ >/dev/null || type fzf-file-widget >/dev/null"' >/dev/null 2>&1
product=/app/code-server/lib/vscode/product.json
if [[ -f "$product" ]]; then
  [[ "$(jq -r '.extensionsGallery.serviceUrl // empty' "$product")" == 'https://marketplace.visualstudio.com/_apis/public/gallery' ]]
  backup=$(mktemp)
  cp "$product" "$backup"
  trap 'cp "$backup" "$product"; rm -f "$backup"' EXIT
  EXTENSIONS_GALLERY=disabled /etc/s6-overlay/s6-rc.d/init-codium-gallery/run
  [[ "$(jq 'has("extensionsGallery")' "$product")" == false ]]
  EXTENSIONS_GALLERY=open-vsx /etc/s6-overlay/s6-rc.d/init-codium-gallery/run
  [[ "$(jq -r '.extensionsGallery.serviceUrl' "$product")" == 'https://open-vsx.org/vscode/gallery' ]]
  EXTENSIONS_GALLERY='{"serviceUrl":"https://custom.gallery/api"}' /etc/s6-overlay/s6-rc.d/init-codium-gallery/run
  [[ "$(jq -r '.extensionsGallery.serviceUrl' "$product")" == 'https://custom.gallery/api' ]]
  EXTENSIONS_GALLERY=default /etc/s6-overlay/s6-rc.d/init-codium-gallery/run
  [[ "$(jq -r '.extensionsGallery.serviceUrl' "$product")" == 'https://marketplace.visualstudio.com/_apis/public/gallery' ]]
fi
