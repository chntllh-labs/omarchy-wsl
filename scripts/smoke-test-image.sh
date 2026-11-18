#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: smoke-test a built .wsl artifact in a throwaway container
# ==============================================================================
#   scripts/smoke-test-image.sh dist/Omarchy-arm64.wsl [--keep-image]
#
# Imports the exact archive users download (docker/podman import), then runs
# the checks below as root in a container from it. Each check prints PASS/FAIL
# with the measured value; the run fails if any check fails.
#   - pacman keyring init + `pacman -Sy` exits 0 with the shipped sandbox
#     (Landlock + DownloadUser=alpm). Container root lacks CAP_SYS_ADMIN, so
#     this one check runs in a second container with no-new-privileges, which
#     lets Landlock apply (and would break setuid sudo for the other checks).
#   - gcc compiles and links a C program (libc_nonshared.a/libgcc intact)
#   - /usr/bin/sudo is 4755, /tmp and /var/tmp are 1777
#   - file capabilities survive the export (newuidmap keeps cap_setuid);
#     ping works unprivileged (cap_net_raw or systemd's ping_group_range)
#   - /usr/lib/wsl/oobe.sh --headless --user devuser provisions uid 1000
#   - omarchy-version matches upstream.lock; the rootfs manifest verifies
#   - systemd-analyze verify of build.slice reports no unknown keys
#   - [omarchy] packages installed, omarchy-wsl is the only foreign package
#
# Environment: CONTAINER_ENGINE, SMOKE_NETWORK (default host; see
# build-reproducible-rootfs.sh for why).
# ==============================================================================

set -uo pipefail

if [[ ${1:-} == --inner-pacman ]]; then
  # ------------------------------------------- in container (no-new-privileges)
  /usr/lib/omarchy-wsl/pacman-init.sh >/dev/null 2>&1 || { echo "  [FAIL] pacman-init failed"; exit 1; }
  if out=$(pacman -Sy --noconfirm 2>&1); then
    printf '  [PASS] pacman -Sy exit 0 with the shipped sandbox (DownloadUser=%s): %s\n' \
      "$(sed -n 's/^DownloadUser *= *//p' /etc/pacman.conf)" "$(grep -c 'downloading' <<<"$out") databases synced"
    exit 0
  fi
  printf '  [FAIL] pacman -Sy failed: %s\n' "$(tail -n 3 <<<"$out" | tr '\n' ' ')"
  exit 1
fi

if [[ ${1:-} == --inner ]]; then
  # ---------------------------------------------------------------- in container
  FAILS=0
  CHECKS=0
  ok() {
    CHECKS=$((CHECKS + 1))
    printf '  [PASS] %s\n' "$*"
  }
  bad() {
    CHECKS=$((CHECKS + 1))
    FAILS=$((FAILS + 1))
    printf '  [FAIL] %s\n' "$*"
  }
  lock() { sed -n "s/^$1=//p" /usr/share/omarchy-wsl/upstream.lock; }
  # expect <pass-message> <fail-message> <command...>
  expect() {
    local yes="$1" no="$2"
    shift 2
    if "$@"; then ok "$yes"; else bad "$no"; fi
  }

  echo "== $(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release) ($(uname -m))"

  if out=$(/usr/lib/omarchy-wsl/pacman-init.sh 2>&1); then ok "pacman keyring initialised (first-boot path)"; else bad "pacman-init: $out"; fi
  # Sync databases for the foreign-package check below. This container keeps
  # setuid working, so pacman's Landlock sandbox cannot apply here; the
  # sandboxed sync is checked separately (--inner-pacman).
  pacman -Sy --noconfirm --disable-sandbox >/dev/null 2>&1 || bad "database sync (--disable-sandbox) failed"
  if pacman-key --list-keys "$(lock OMARCHY_KEY_FPR)" >/dev/null 2>&1; then ok "Omarchy key $(lock OMARCHY_KEY_FPR) trusted"; else bad "Omarchy key not in keyring"; fi

  tmpc=$(mktemp -d)
  if echo 'int main(){return 0;}' | gcc -x c - -o "$tmpc/t" 2>"$tmpc/err" && "$tmpc/t"; then
    ok "gcc: echo 'int main(){return 0;}' | gcc -x c - -o /tmp/t && /tmp/t -> 0"
  else
    bad "gcc link failed: $(head -n 3 "$tmpc/err" | tr '\n' ' ')"
  fi

  m=$(stat -c %a /usr/bin/sudo)
  if [[ $m == 4755 ]]; then ok "stat -c %a /usr/bin/sudo = $m"; else bad "stat -c %a /usr/bin/sudo = $m (expected 4755)"; fi
  m=$(stat -c %a /var/tmp)
  if [[ $m == 1777 ]]; then ok "stat -c %a /var/tmp = $m"; else bad "stat -c %a /var/tmp = $m (expected 1777)"; fi
  m=$(stat -c %a /tmp)
  if [[ $m == 1777 ]]; then ok "stat -c %a /tmp = $m"; else bad "stat -c %a /tmp = $m (expected 1777)"; fi

  ucap=$(getcap /usr/bin/newuidmap 2>/dev/null || true)
  if [[ $ucap == *cap_setuid* ]]; then ok "file capabilities survive the export: $ucap"; else bad "newuidmap lost cap_setuid ('$ucap')"; fi
  caps=$(getcap /usr/bin/ping 2>/dev/null || true)
  ping_range=$(grep -hsE '^-?net\.ipv4\.ping_group_range' /usr/lib/sysctl.d/*.conf /etc/sysctl.d/*.conf | tail -n 1)
  if [[ $caps == *cap_net_raw* ]]; then
    ok "getcap /usr/bin/ping: $caps"
  elif [[ -n $ping_range ]]; then
    ok "ping uses unprivileged ICMP sockets (no file caps needed): ${ping_range}"
  else
    bad "ping has neither cap_net_raw nor a ping_group_range sysctl"
  fi

  if out=$(/usr/lib/wsl/oobe.sh --headless --user devuser 2>&1); then
    uid=$(id -u devuser 2>/dev/null)
    home=$(getent passwd devuser | cut -d: -f6)
    if [[ $uid == 1000 && -d $home && $(stat -c '%U %a' "$home") == "devuser 700" ]]; then
      ok "oobe.sh --headless --user devuser -> uid $uid, home $home ($(stat -c '%U %a' "$home"))"
    else
      bad "OOBE exit 0 but uid=$uid home=$home"
    fi
    if visudo -c >/dev/null 2>&1 && runuser -u devuser -- sudo -n true 2>/dev/null; then
      ok "sudoers valid; devuser has sudo (/etc/sudoers.d/10-devuser)"
    else
      bad "sudo for devuser not working"
    fi
    expect "/etc/wsl.conf [user] default = devuser" "/etc/wsl.conf default user not set" grep -qE '^default[[:space:]]*=[[:space:]]*devuser$' /etc/wsl.conf
    if [[ -f /var/lib/systemd/linger/devuser ]]; then ok "linger enabled for devuser"; else bad "no linger marker"; fi
    if out2=$(/usr/lib/wsl/oobe.sh --headless --user devuser 2>&1); then ok "OOBE re-run is a no-op (exit 0)"; else bad "OOBE re-run failed: $(tail -n 2 <<<"$out2" | tr '\n' ' ')"; fi
  else
    bad "oobe.sh failed: $(tail -n 5 <<<"$out" | tr '\n' ' ')"
  fi

  v=$(omarchy-version 2>&1)
  if [[ $v == "$(lock OMARCHY_VERSION)" ]]; then ok "omarchy-version = $v"; else bad "omarchy-version = '$v' (expected $(lock OMARCHY_VERSION))"; fi
  if out=$(/usr/lib/omarchy-wsl/install-manifest --verify / 2>&1); then ok "manifest: ${out##*: }"; else bad "manifest drift: $(head -n 5 <<<"$out" | tr '\n' ' ')"; fi
  if out=$(pacman -Qkk omarchy-wsl 2>&1 | tail -n 1); then ok "pacman -Qkk omarchy-wsl: $out"; else bad "pacman -Qkk omarchy-wsl: $out"; fi

  if systemd-analyze verify /etc/systemd/system/build.slice 2>&1 | grep -i unknown; then
    bad "systemd-analyze verify build.slice reports unknown keys"
  else
    ok "! systemd-analyze verify /etc/systemd/system/build.slice | grep -i unknown"
  fi

  missing=""
  for p in omarchy-keyring omarchy-nvim yay mise-bin omarchy-wsl tmux neovim git docker; do
    pacman -Q "$p" >/dev/null 2>&1 || missing+=" $p"
  done
  if [[ -z $missing ]]; then ok "packages present: $(pacman -Q omarchy-wsl omarchy-keyring omarchy-nvim yay mise-bin | tr '\n' ' ')"; else bad "missing packages:$missing"; fi
  foreign=$(pacman -Qmq | tr '\n' ' ')
  if [[ $foreign == "omarchy-wsl " ]]; then ok "pacman -Qm: only omarchy-wsl"; else bad "foreign packages: $foreign"; fi
  for f in /usr/lib/wsl/omarchy.ico /usr/lib/wsl/terminal-profile.json /usr/lib/wsl/oobe.sh; do
    s=$(stat -c %s "$f")
    if ((s < 1048576)); then ok "$f $s bytes (< 1 MiB)"; else bad "$f is $s bytes"; fi
  done
  r=$(awk -F: '$1=="root"{print $2}' /etc/shadow)
  if [[ $r == '!*' ]]; then ok "root locked without hash ('$r')"; else bad "root shadow field '$r'"; fi
  echo "== smoke: $((CHECKS - FAILS))/$CHECKS checks passed, $FAILS failed"
  exit $((FAILS > 0))
fi

# -------------------------------------------------------------------- on the host
ARTIFACT="${1:?usage: smoke-test-image.sh <Omarchy-*.wsl> [--keep-image]}"
KEEP=0
[[ ${2:-} == --keep-image ]] && KEEP=1
[[ -f $ARTIFACT ]] || {
  echo "no such file: $ARTIFACT" >&2
  exit 2
}
ENGINE="${CONTAINER_ENGINE:-$(command -v docker || command -v podman)}"
[[ -n $ENGINE ]] || {
  echo "docker or podman required" >&2
  exit 2
}
case "$(basename "$ARTIFACT")" in
  *arm64*) PLATFORM=linux/arm64 ;;
  *x86_64*) PLATFORM=linux/amd64 ;;
  *) PLATFORM="" ;;
esac
TAG="omarchy-wsl-smoke:$$"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() { ((KEEP)) || $ENGINE rmi -f "$TAG" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[smoke] importing $ARTIFACT ($(stat -c %s "$ARTIFACT" 2>/dev/null || stat -f %z "$ARTIFACT") bytes)"
$ENGINE import ${PLATFORM:+--platform "$PLATFORM"} "$ARTIFACT" "$TAG" >/dev/null
rc=0
$ENGINE run --rm ${PLATFORM:+--platform "$PLATFORM"} --network "${SMOKE_NETWORK:-host}" \
  --security-opt no-new-privileges -v "$SELF:/smoke.sh:ro" "$TAG" /bin/bash /smoke.sh --inner-pacman || rc=1
$ENGINE run --rm ${PLATFORM:+--platform "$PLATFORM"} --network "${SMOKE_NETWORK:-host}" \
  -v "$SELF:/smoke.sh:ro" "$TAG" /bin/bash /smoke.sh --inner || rc=1
exit "$rc"
