#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' '=== Phase 4 pnpm Compatibility Verification ==='
printf '%s\n' 'SHIM-01 SHIM-02 SHIM-03'

expected_prefix='/usr/local/go/bin:/opt/rust/cargo/bin:/config/.local/share/pnpm:/usr/local/bin:/usr/bin:/bin'
case "$PATH" in "$expected_prefix"*) ;; *) printf '%s\n' 'SHIM-01: canonical PATH is not pnpm-first' >&2; exit 1;; esac
[[ "$(command -v pnpm)" == /usr/local/bin/pnpm || "$(command -v pnpm)" == /config/.local/share/pnpm/* ]]
[[ "$(command -v npm)" == /usr/bin/npm ]]
[[ ! -e /usr/local/bin/npm ]]
npm --version | grep -Eq '^[0-9]+\.'
[[ "$(command -v npx)" == /usr/local/bin/npx ]]
[[ "$(command -v yarn)" == /usr/local/bin/yarn ]]
pnpm --version >/dev/null
printf '%s\n' 'SHIM-01: pnpm precedence and native npm passed'

for binary in npx yarn; do
    test -x "/usr/local/bin/$binary"
    test -x "/usr/local/bin/${binary}-native"
    "$binary" --version | grep -Fq 'codium'
done
npx-native --version >/dev/null
yarn-native --version >/dev/null
CODIUM_BYPASS_SHIMS=1 npx --version | grep -Eq '^[0-9]+\.'
CODIUM_BYPASS_SHIMS=1 yarn --version | grep -Eq '^[0-9]+\.'
printf '%s\n' 'SHIM-03: npx/yarn native escape hatches passed'

fixture=$(mktemp -d)
authorized_keys=/config/.ssh/authorized_keys
restore_authorized_keys=0
cleanup() {
    if [[ "$restore_authorized_keys" -eq 1 ]]; then
        cp -a "$fixture/authorized_keys" "$authorized_keys"
    else
        rm -f "$authorized_keys"
    fi
    rm -f "${dlx_archive:-}"
    rm -rf "$fixture"
}
trap cleanup EXIT
cd "$fixture"

make_package() {
    local directory=$1 name=$2
    mkdir -p "$directory"
    printf '{"name":"%s","version":"1.0.0"}\n' "$name" > "$directory/package.json"
}

assert_dependency() {
    local name=$1
    node -e 'const name=process.argv[1]; const p=require("./package.json"); if (!p.dependencies?.[name]) process.exit(1)' "$name"
    [[ -d "node_modules/$name" ]]
}

make_package packages/yarn-bare yarn-bare-dependency
make_package packages/yarn-add yarn-add-dependency
make_package packages/yarn-upgrade yarn-upgrade-dependency
mkdir -p packages/dlx-tool/bin
printf '%s\n' '{"name":"codium-dlx-tool","version":"1.0.0","bin":{"codium-dlx-tool":"bin/run"}}' > packages/dlx-tool/package.json
printf '%s\n' '#!/bin/sh' 'printf "dlx-exec:%s" "$*"' > packages/dlx-tool/bin/run
chmod +x packages/dlx-tool/bin/run
(cd packages/dlx-tool && pnpm pack --pack-destination /tmp >/dev/null)
dlx_archive=/tmp/codium-dlx-tool-1.0.0.tgz

printf '%s\n' '{"name":"codium-shim-fixture","version":"1.0.0","scripts":{"test":"printf fixture-test","hello":"printf fixture-run"}}' > package.json
node -e 'const fs=require("fs"); const p=require("./package.json"); p.dependencies={"yarn-bare-dependency":"file:packages/yarn-bare"}; fs.writeFileSync("package.json", JSON.stringify(p)+"\n")'
yarn >/dev/null
assert_dependency yarn-bare-dependency
rm -rf node_modules/yarn-bare-dependency
yarn install --offline >/dev/null
assert_dependency yarn-bare-dependency
yarn add ./packages/yarn-add --offline >/dev/null
assert_dependency yarn-add-dependency
yarn remove yarn-add-dependency --offline >/dev/null
node -e 'const p=require("./package.json"); if (p.dependencies?.["yarn-add-dependency"] || require("fs").existsSync("node_modules/yarn-add-dependency")) process.exit(1)'
node -e 'const fs=require("fs"); const p=require("./package.json"); p.dependencies["yarn-upgrade-dependency"]="file:packages/yarn-upgrade"; fs.writeFileSync("package.json", JSON.stringify(p)+"\n")'
rm -rf node_modules/yarn-upgrade-dependency
yarn upgrade --offline >/dev/null
assert_dependency yarn-upgrade-dependency

yarn run hello | grep -Fq fixture-run
yarn test | grep -Fq fixture-test
mkdir -p node_modules/.bin
printf '#!/bin/sh\nprintf local-exec\n' > node_modules/.bin/codium-local
chmod +x node_modules/.bin/codium-local
npx codium-local | grep -Fq local-exec
npx --no-install codium-local | grep -Fq local-exec
[[ ! -e node_modules/.bin/codium-dlx-tool ]]
npx "$dlx_archive" dlx-argument 2>&1 | tee "$fixture/dlx-output"
grep -Fq 'dlx-exec:' "$fixture/dlx-output"
[[ ! -e node_modules/.bin/codium-dlx-tool ]]

[[ -e pnpm-lock.yaml && ! -e package-lock.json && ! -e yarn.lock ]]
printf '%s\n' 'SHIM-02: yarn/npx compatibility matrix passed'

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
reject yarn set version
reject yarn plugin import foo
reject yarn publish
printf '%s\n' 'SHIM-03: fail-closed yarn diagnostics passed'

check_shell() {
    local shell_command=$1
    local path
    path=$(bash -c "$shell_command" 2>/dev/null)
    case "$path" in "$expected_prefix"*) ;; *) return 1;; esac
}
check_shell 'printf %s "$PATH"'
check_shell 'bash -i -c '\''printf %s "$PATH"'\'''
check_shell 'bash -l -c '\''printf %s "$PATH"'\'''
if command -v ssh >/dev/null 2>&1 && timeout 1 bash -c '</dev/tcp/127.0.0.1/2222' 2>/dev/null; then
    client_key="$fixture/ssh_client_ed25519"
    ssh-keygen -q -t ed25519 -N '' -f "$client_key"
    mkdir -p /config/.ssh
    chmod 0700 /config/.ssh
    if [[ -f "$authorized_keys" ]]; then
        cp -a "$authorized_keys" "$fixture/authorized_keys"
        restore_authorized_keys=1
    fi
    cp "$client_key.pub" "$authorized_keys"
    chown -R abc:abc /config/.ssh
    chmod 0600 "$authorized_keys"
    ssh_options=(-p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR -i "$client_key")
    ssh_path=$(ssh "${ssh_options[@]}" abc@127.0.0.1 'printf %s "$PATH"')
    case "$ssh_path" in "$expected_prefix"*) ;; *) exit 1;; esac
fi
printf '%s\n' 'Shell parity passed'
printf '%s\n' '=== All Phase 4 Verification Checks PASSED ==='
