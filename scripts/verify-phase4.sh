#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' '=== Phase 4 pnpm Compatibility Verification ==='
printf '%s\n' 'SHIM-01 SHIM-02 SHIM-03 SHIM-04'

expected='/usr/local/go/bin:/opt/rust/cargo/bin:/usr/local/bin:/config/.local/share/pnpm:/usr/bin:/bin'
case "$PATH" in "$expected"*) ;; *) printf '%s\n' 'SHIM-01: canonical PATH is not pnpm-first' >&2; exit 1;; esac
[[ "$(command -v pnpm)" == /usr/local/bin/pnpm || "$(command -v pnpm)" == /config/.local/share/pnpm/* ]]
[[ "$(command -v npm)" == /usr/local/bin/npm ]]
[[ "$(command -v npx)" == /usr/local/bin/npx ]]
[[ "$(command -v yarn)" == /usr/local/bin/yarn ]]
pnpm --version >/dev/null
printf '%s\n' 'SHIM-01: pnpm precedence passed'

for binary in npm npx yarn; do
    test -x "/usr/local/bin/$binary"
    test -x "/usr/local/bin/${binary}-native"
    "$binary" --version | grep -Fq 'codium'
done
npm-native --version >/dev/null
npx-native --version >/dev/null
yarn-native --version >/dev/null
CODIUM_BYPASS_SHIMS=1 npm --version | grep -Eq '^[0-9]+\.'
CODIUM_BYPASS_SHIMS=1 npx --version | grep -Eq '^[0-9]+\.'
CODIUM_BYPASS_SHIMS=1 yarn --version | grep -Eq '^[0-9]+\.'
printf '%s\n' 'SHIM-04: native escape hatches passed'

fixture=$(mktemp -d)
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT
cd "$fixture"
printf '%s\n' '{"name":"codium-shim-fixture","version":"1.0.0","scripts":{"test":"printf fixture-test","hello":"printf fixture-run"}}' > package.json
mkdir -p node_modules/.bin
printf '#!/bin/sh\nprintf local-exec\n' > node_modules/.bin/codium-local
chmod +x node_modules/.bin/codium-local

pnpm install --offline >/dev/null
npm run hello | grep -Fq fixture-run
npm test | grep -Fq fixture-test
npm exec codium-local | grep -Fq local-exec
npx --no-install codium-local | grep -Fq local-exec
yarn run hello | grep -Fq fixture-run
yarn test | grep -Fq fixture-test
[[ ! -e package-lock.json && ! -e yarn.lock ]]
printf '%s\n' 'SHIM-02: supported local translations passed'

reject() {
    local output status
    set +e
    output=$("$@" 2>&1)
    status=$?
    set -e
    [[ "$status" -eq 1 ]]
    [[ "$output" == *'[codium-shim]'* ]]
    [[ "$output" == *'native'* || "$output" == *'pnpm'* ]]
}
reject npm publish
reject npm login
reject npm audit fix
reject yarn set version
reject yarn plugin import foo
reject yarn publish
printf '%s\n' 'SHIM-03: fail-closed diagnostics passed'

check_shell() {
    local shell_command=$1
    local path
    path=$(bash -c "$shell_command")
    case "$path" in "$expected"*) ;; *) return 1;; esac
}
check_shell 'printf %s "$PATH"'
check_shell 'bash -i -c "printf %s \\\"$PATH\\\""'
check_shell 'bash -l -c "printf %s \\\"$PATH\\\""'
if command -v ssh >/dev/null 2>&1 && timeout 1 bash -c '</dev/tcp/127.0.0.1/2222' 2>/dev/null; then
    ssh_options=(-p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR)
    ssh_path=$(ssh "${ssh_options[@]}" abc@127.0.0.1 'bash -lc "printf %s \\\"$PATH\\\""')
    case "$ssh_path" in "$expected"*) ;; *) exit 1;; esac
fi
printf '%s\n' 'Shell parity passed'
printf '%s\n' '=== All Phase 4 Verification Checks PASSED ==='
