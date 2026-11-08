#!/bin/bash
# Private, transactional dependency setup. No shell profile or global package changes.
set -euo pipefail
set -m
umask 077
launcher_runtime_root=${1:?Missing private Runtime directory}
launcher_existing_bun=${2:-}
case "$launcher_runtime_root" in /*/Runtime) ;; *) printf '%s\n' 'ERROR: expected an absolute private Runtime directory.' >&2; exit 2;; esac
launcher_macos=$(/usr/bin/sw_vers -productVersion)
if [ "${launcher_macos%%.*}" -lt 13 ]; then printf '%s\n' 'ERROR: macOS 13 or newer is required.' >&2; exit 2; fi
/bin/mkdir -p "$launcher_runtime_root"
/bin/chmod 700 "$launcher_runtime_root"
launcher_stage=$(/usr/bin/mktemp -d "$launcher_runtime_root/.setup.XXXXXXXX")
launcher_lock="$launcher_runtime_root/.setup.lock"
if ! /bin/mkdir "$launcher_lock" 2>/dev/null; then
    /bin/rm -rf -- "$launcher_stage"
    printf '%s\n' 'ERROR: another setup owns this Runtime folder. Close it before retrying.' >&2
    exit 4
fi
launcher_child_pid=''
launcher_committed=0
launcher_bun_published=0
launcher_packages_published=0
launcher_cancel() {
    trap '' TERM INT
    if [ -n "$launcher_child_pid" ]; then
        kill -TERM -- "-$launcher_child_pid" 2>/dev/null || kill -TERM "$launcher_child_pid" 2>/dev/null || true
        wait "$launcher_child_pid" 2>/dev/null || true
    fi
    printf '%s\n' 'SETUP CANCELLED: previous completed installation retained.' >&2
    exit 130
}
launcher_cleanup() {
    launcher_status=$?
    trap - EXIT
    if [ "$launcher_committed" -eq 0 ]; then
        if [ "$launcher_packages_published" -eq 1 ] && [ -d "$launcher_runtime_root/packages" ]; then
            /bin/mv "$launcher_runtime_root/packages" "$launcher_stage/failed-packages" || true
        fi
        if [ "$launcher_bun_published" -eq 1 ] && [ -d "$launcher_runtime_root/bun" ]; then
            /bin/mv "$launcher_runtime_root/bun" "$launcher_stage/failed-bun" || true
        fi
        if [ -d "$launcher_stage/previous-packages" ]; then /bin/mv "$launcher_stage/previous-packages" "$launcher_runtime_root/packages" || true; fi
        if [ -d "$launcher_stage/previous-bun" ]; then /bin/mv "$launcher_stage/previous-bun" "$launcher_runtime_root/bun" || true; fi
    fi
    /bin/rm -rf -- "$launcher_stage"
    /bin/rmdir "$launcher_lock" 2>/dev/null || true
    exit "$launcher_status"
}
trap launcher_cancel TERM INT
trap launcher_cleanup EXIT
launcher_run() {
    "$@" &
    launcher_child_pid=$!
    local launcher_status
    if wait "$launcher_child_pid"; then launcher_status=0; else launcher_status=$?; fi
    launcher_child_pid=''
    return "$launcher_status"
}
launcher_publish_bun=0
if [ -n "$launcher_existing_bun" ] && [ -x "$launcher_existing_bun" ]; then
    launcher_bun="$launcher_existing_bun"
    printf '%s\n' 'SETUP 1/3: reusing compatible installed Bun.'
else
    case "$(/usr/bin/uname -m)" in
        arm64) launcher_asset=bun-darwin-aarch64; launcher_digest=80afd4c069b46a6fa8f3ec520bebc750a7843e4a8d5b9583d29ad436c00a3403;;
        x86_64) launcher_asset=bun-darwin-x64-baseline; launcher_digest=0fde04e8b092156b97fe6432e899baf16d9ed6ce52cbb4218d2d9c07a2f827ef;;
        *) printf '%s\n' 'ERROR: unsupported Mac CPU.' >&2; exit 2;;
    esac
    printf '%s\n' 'SETUP 1/3: downloading Bun 1.4.3 from the official GitHub release.'
    launcher_run /usr/bin/curl --fail --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 600 --retry 1 --output "$launcher_stage/bun.zip" "https://github.com/oven-sh/bun/releases/download/bun-v1.4.3/$launcher_asset.zip"
    launcher_actual=$(/usr/bin/shasum -a 256 "$launcher_stage/bun.zip")
    launcher_actual=${launcher_actual%% *}
    if [ "$launcher_actual" != "$launcher_digest" ]; then printf '%s\n' 'ERROR: official Bun archive SHA256 did not match. Nothing was installed.' >&2; exit 3; fi
    launcher_run /usr/bin/unzip -q "$launcher_stage/bun.zip" -d "$launcher_stage/unpack"
    /bin/mkdir -p "$launcher_stage/new-bun/bin"
    /bin/cp "$launcher_stage/unpack/$launcher_asset/bun" "$launcher_stage/new-bun/bin/bun"
    /bin/chmod 700 "$launcher_stage/new-bun/bin/bun"
    launcher_bun="$launcher_stage/new-bun/bin/bun"
    launcher_publish_bun=1
fi
# Avoid any dependence on the app bundle directory, caller's working directory or shell startup files.
export BUN_INSTALL_CACHE_DIR="$launcher_stage/cache"
export BUN_CONFIG_NO_CLEAR_TERMINAL=1
export DO_NOT_TRACK=1
export PATH="$(/usr/bin/dirname "$launcher_bun"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
launcher_run "$launcher_bun" -e 'const v=process.versions.bun.split(".").map(Number);if(v[0]<1||(v[0]===1&&v[1]<4))throw Error("Bun 1.4 or newer is required")'
printf '%s\n' 'SETUP 2/3: installing Delegatus 1.11.0 in this user private Runtime folder.'
/bin/mkdir -p "$launcher_stage/new-packages"
cat > "$launcher_stage/new-packages/package.json" <<'JSON'
{"name":"delegatus-community-launcher-runtime","private":true,"dependencies":{"delegatus-cli":"1.11.0"},"trustedDependencies":["sharp","unrs-resolver"]}
JSON
launcher_run "$launcher_bun" install --cwd "$launcher_stage/new-packages" --no-progress
launcher_run "$launcher_bun" -e 'const fs=require("node:fs");const p=JSON.parse(fs.readFileSync(process.argv.at(-1),"utf8"));if(p.name!=="delegatus-cli"||p.version!=="1.11.0")throw Error("Incorrect Delegatus package")' "$launcher_stage/new-packages/node_modules/delegatus-cli/package.json"
test -f "$launcher_stage/new-packages/node_modules/delegatus-cli/bin/cli.mjs"
printf '%s\n' 'SETUP 3/3: publishing the verified private installation.'
# Publication is a short transaction: defer cancellation until both verified pieces are in place.
trap '' TERM INT
if [ "$launcher_publish_bun" -eq 1 ]; then
    if [ -e "$launcher_runtime_root/bun" ]; then /bin/mv "$launcher_runtime_root/bun" "$launcher_stage/previous-bun"; fi
    /bin/mv "$launcher_stage/new-bun" "$launcher_runtime_root/bun"
    launcher_bun_published=1
fi
if [ -e "$launcher_runtime_root/packages" ]; then /bin/mv "$launcher_runtime_root/packages" "$launcher_stage/previous-packages"; fi
/bin/mv "$launcher_stage/new-packages" "$launcher_runtime_root/packages"
launcher_packages_published=1
launcher_committed=1
trap launcher_cancel TERM INT
printf '%s\n' 'SETUP COMPLETE: Bun and Delegatus are ready. Global installations were preserved.'
