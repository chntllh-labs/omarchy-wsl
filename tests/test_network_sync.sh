#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: Network Sync Tools Test Suite
# tests/test_network_sync.sh
# ==============================================================================
# omarchy-proxy-sync, omarchy-ca-sync, omarchy-dns-sync, omarchy-mirror-sync and
# omarchy-netdoctor run for real against a simulated Windows host (stub
# powershell.exe that records the decoded -EncodedCommand script and replies
# with a fixture), a sandboxed /etc (seams), and stub curl/ip binaries.
# Nothing outside the mktemp sandbox is touched.
#
# Tools used when present: openssl (certificate fixtures), pwsh (parses the
# generated PowerShell), systemd-analyze (unit verification), shellcheck.
# OMW_STRICT=1 turns every skip into a failing exit status.
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_OK=$'\e[32m' C_BAD=$'\e[31m' C_SKIP=$'\e[33m' C_HDR=$'\e[1;36m' C_END=$'\e[0m'
else
  C_OK="" C_BAD="" C_SKIP="" C_HDR="" C_END=""
fi
pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); printf '  %s[PASS]%s %s\n' "$C_OK" "$C_END" "$*"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); printf '  %s[FAIL]%s %s\n' "$C_BAD" "$C_END" "$*"; }
skip() { TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); printf '  %s[SKIP]%s %s\n' "$C_SKIP" "$C_END" "$*"; }
header() { printf '\n%s>>> %s%s\n' "$C_HDR" "$*" "$C_END"; }
check() { local desc="$1"; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }

BIN="$ROOT_DIR/bin"
PWSH="${PWSH:-$(command -v pwsh || true)}"
T=$(mktemp -d "${TMPDIR:-/tmp}/omw-net.XXXXXX")
# shellcheck disable=SC2317  # invoked by the EXIT trap
cleanup() { if [[ -n "${OMW_TEST_KEEP:-}" ]]; then echo "sandbox kept: $T"; else rm -rf "$T"; fi; }
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Simulated Windows host
# -----------------------------------------------------------------------------
MNT="$T/mnt"
SYS32="$MNT/c/Windows/System32"
LOG="$T/log"
mkdir -p "$SYS32/WindowsPowerShell/v1.0" "$LOG" "$T/run" "$T/home" "$T/fakebin" "$T/etc"
chmod 0700 "$T/run"
cat >"$SYS32/WindowsPowerShell/v1.0/powershell.exe" <<EOF
#!/usr/bin/env bash
enc=""
while [[ \$# -gt 0 ]]; do
  [[ "\$1" == "-EncodedCommand" ]] && enc="\$2"
  [[ "\$1" == "-Command" ]] && echo "unexpected -Command" >>"$LOG/violations"
  shift
done
n=\$(( \$(find "$LOG" -maxdepth 1 -name 'ps.*.ps1' | wc -l) + 1 ))
printf '%s' "\$enc" | base64 -d | iconv -f UTF-16LE -t UTF-8 >"$LOG/ps.\$n.ps1"
[[ -n "\${FAKE_PS_SLEEP:-}" ]] && sleep "\$FAKE_PS_SLEEP"
if [[ -n "\${FAKE_PS_OUT:-}" && -f "\${FAKE_PS_OUT}" ]]; then cat "\$FAKE_PS_OUT"; fi
exit "\${FAKE_PS_RC:-0}"
EOF
chmod +x "$SYS32/WindowsPowerShell/v1.0/powershell.exe"
printf '#!/usr/bin/env bash\nprintf "%%s\\r\\n" "C:\\\\Users\\\\Jane Doe"\n' >"$SYS32/cmd.exe"
chmod +x "$SYS32/cmd.exe"

export OMW_FORCE_WSL=1 OMW_FORCE_INTEROP=1 OMW_MOUNT_ROOT="$MNT"
export XDG_RUNTIME_DIR="$T/run" HOME="$T/home" OMW_WSL_RUN_DIR="$T/no-run-wsl"
unset WSL_INTEROP http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
ps_count() { find "$LOG" -maxdepth 1 -name 'ps.*.ps1' | wc -l; }
ps_last() { echo "$LOG/ps.$(ps_count).ps1"; }
reset_logs() { rm -f "$LOG"/*; }

cat >"$T/parse.ps1" <<'PS'
param([string]$Path)
$errs = $null; $tok = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$errs)
if ($errs.Count) { $errs | ForEach-Object { [Console]::Error.WriteLine($_.Message) }; exit 1 }
PS
pwsh_check() {
  if [[ -z "$PWSH" ]]; then skip "pwsh not installed: $1"; return; fi
  check "$1" "$PWSH" -NoProfile -NonInteractive -File "$T/parse.ps1" -Path "$2"
}

# =============================================================================
header "0. Static checks"
NET_TOOLS=("$BIN/omarchy-proxy-sync" "$BIN/omarchy-ca-sync" "$BIN/omarchy-dns-sync" "$BIN/omarchy-mirror-sync" "$BIN/omarchy-netdoctor")
bad=0
for f in "${NET_TOOLS[@]}"; do bash -n "$f" || bad=1; done
check "bash -n on every network tool" test "$bad" -eq 0
if have shellcheck; then
  check "shellcheck -x clean (network tools, this suite)" \
    bash -c "cd '$ROOT_DIR' && shellcheck -x bin/omarchy-proxy-sync bin/omarchy-ca-sync bin/omarchy-dns-sync bin/omarchy-mirror-sync bin/omarchy-netdoctor tests/test_network_sync.sh"
else
  skip "shellcheck not installed"
fi
check "No tool calls powershell.exe with -Command" \
  bash -c "! grep -n 'powershell.exe.* -Command\\|-Command \"' $(printf '%q ' "${NET_TOOLS[@]}")"
check "No tool sources a state or config file" \
  bash -c "! grep -nE '^[[:space:]]*(source|\\.)[[:space:]]+\"?\\\$(STATE|PERSIST|CONF)' $(printf '%q ' "${NET_TOOLS[@]}")"
check "No hard-coded /mnt/c PowerShell path" bash -c "! grep -n '/mnt/c/Windows' $(printf '%q ' "${NET_TOOLS[@]}")"

# =============================================================================
header "1. omarchy-proxy-sync"
ENVC="$T/etc/environment.d/10-omarchy-proxy.conf"
PROF="$T/etc/profile.d/10-omarchy-proxy.sh"
export OMARCHY_PROXY_ENV_CONF="$ENVC" OMARCHY_PROXY_PROFILE_SH="$PROF"
b64() { printf '%s' "$1" | base64 -w0; }
proxy_fixture() {  # <enabled> <server> [override] [pac]
  printf 'ENABLED=%s\nSERVER=%s\nOVERRIDE=%s\nPAC=%s\nEND=1\n' "$1" "$(b64 "$2")" "$(b64 "${3:-}")" "$(b64 "${4:-}")" >"$T/proxy.out"
}
P="$BIN/omarchy-proxy-sync"

proxy_fixture 1 'proxy.corp.example:8080' '<local>;*.corp.example;10.*;10.20.30.*;intranet'
reset_logs
FAKE_PS_OUT="$T/proxy.out" "$P" -q; rc=$?
check "Valid host:port is accepted (exit 0)" test "$rc" -eq 0
check "Query goes through omw_ps_run (EncodedCommand; no -Command)" bash -c "[[ -s '$(ps_last)' && ! -e '$LOG/violations' ]]"
pwsh_check "Proxy query PowerShell parses (pwsh)" "$(ps_last)"
check "profile.d: values are single-quoted exports" \
  bash -c "grep -qx \"export http_proxy='http://proxy.corp.example:8080'\" '$PROF' && grep -qx \"export HTTPS_PROXY='http://proxy.corp.example:8080'\" '$PROF'"
check "environment.d: KEY='value' lines only" bash -c "grep -v '^#' '$ENVC' | grep -qvE \"^[A-Za-z_]+='[^']*'\$\" && exit 1 || exit 0"
check "ProxyOverride converted for no_proxy (wildcards -> CIDR / domains)" \
  grep -q "no_proxy='localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.local,.internal,.corp.example,10.0.0.0/8,10.20.30.0/24,intranet'" "$PROF"
out=$(env -i PATH=/usr/bin:/bin sh -c ". '$PROF'; echo \"\$http_proxy|\$no_proxy\"")
check "Generated profile sources cleanly in sh" bash -c "[[ \"\$1\" == 'http://proxy.corp.example:8080|localhost,'* ]]" _ "$out"

for evil in 'evil.example:8080$(touch '"$T"'/pwned1)' 'evil.example:8080`touch '"$T"'/pwned2`' \
            $'evil.example:8080\ntouch '"$T"'/pwned3' "evil.example:8080';touch $T/pwned4;'" 'http=evil:80;https=$(id):443'; do
  cp "$PROF" "$T/prof.before"
  proxy_fixture 1 "$evil"
  FAKE_PS_OUT="$T/proxy.out" "$P" -q 2>/dev/null; rc=$?
  check "Rejects hostile ProxyServer $(printf '%q' "${evil:19:16}")... (exit 3, files untouched)" \
    bash -c "[[ $rc -eq 3 ]] && cmp -s '$T/prof.before' '$PROF'"
done
env -i PATH=/usr/bin:/bin bash -c ". '$PROF'" >/dev/null 2>&1
check "Nothing hostile was ever executed (no pwned files)" bash -c "! compgen -G '$T/pwned*' >/dev/null"
proxy_fixture 1 'proxy.corp.example:8080' '*.ok.example;$(touch '"$T"'/pwned5)'
FAKE_PS_OUT="$T/proxy.out" "$P" -q 2>/dev/null; rc=$?
check "Rejects a hostile ProxyOverride entry (exit 3)" bash -c "[[ $rc -eq 3 && ! -e '$T/pwned5' ]]"

proxy_fixture 1 'http=web.example:3128;https=secure.example:3129;socks=socks.example:1080'
FAKE_PS_OUT="$T/proxy.out" "$P" -q; rc=$?
check "Per-protocol form parsed (http/https/socks)" \
  bash -c "[[ $rc -eq 0 ]] && grep -qx \"export http_proxy='http://web.example:3128'\" '$PROF' && grep -qx \"export https_proxy='http://secure.example:3129'\" '$PROF' && grep -qx \"export all_proxy='socks4://socks.example:1080'\" '$PROF' && ! grep -q '^export ftp_proxy' '$PROF'"
proxy_fixture 1 'https://[fd00::1]:8443'
FAKE_PS_OUT="$T/proxy.out" "$P" -q; rc=$?
check "Scheme and bracketed IPv6 host accepted" bash -c "[[ $rc -eq 0 ]] && grep -qxF \"export https_proxy='https://[fd00::1]:8443'\" '$PROF'"
proxy_fixture 1 'proxy.example:99999'
FAKE_PS_OUT="$T/proxy.out" "$P" -q 2>/dev/null; rc=$?
check "Port out of range rejected" test "$rc" -eq 3

cp "$PROF" "$T/prof.before"
FAKE_PS_RC=1 FAKE_PS_OUT=/dev/null "$P" -q 2>/dev/null; rc=$?
check "Windows query failure: exit 1, configuration untouched" bash -c "[[ $rc -eq 1 ]] && cmp -s '$T/prof.before' '$PROF'"
proxy_fixture 0 ''
FAKE_PS_OUT="$T/proxy.out" "$P" -q; rc=$?
check "Proxy disabled in Windows: stale files removed" bash -c "[[ $rc -eq 0 && ! -e '$PROF' && ! -e '$ENVC' ]]"
proxy_fixture 0 '' '' 'http://wpad.example/proxy.pac'
out=$(FAKE_PS_OUT="$T/proxy.out" "$P" 2>&1)
check "PAC configuration is reported, not silently ignored" grep -q 'PAC' <<<"$out"
proxy_fixture 1 'proxy.example:8080'
out=$(FAKE_PS_OUT="$T/proxy.out" "$P" --dry-run)
check "--dry-run prints the files and writes nothing" bash -c "[[ \"\$1\" == *\"export http_proxy='http://proxy.example:8080'\"* && ! -e '$PROF' ]]" _ "$out"

# =============================================================================
header "2. omarchy-ca-sync"
C="$BIN/omarchy-ca-sync"
ANCH="$T/anchors"
mkdir -p "$ANCH"
export OMARCHY_CA_ANCHORS_DIR="$ANCH" OMARCHY_CA_BUNDLE="$T/bundle.pem" OMARCHY_CA_CONF="$T/ca-sync.conf"
export OMARCHY_CA_UPDATE_CMD="$T/fakebin/update-ca-trust"
printf '#!/bin/sh\necho run >>%s/update.calls\n' "$LOG" >"$T/fakebin/update-ca-trust"
chmod +x "$T/fakebin/update-ca-trust"
if have openssl; then
  mkcert() {  # <name>
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
      -subj "/CN=Omarchy Test Root $1" -keyout "$T/$1.key" -out "$T/$1.pem" >/dev/null 2>&1
    openssl x509 -in "$T/$1.pem" -outform DER -out "$T/$1.der"
  }
  for n in A B C; do mkcert "$n"; done
  thumb() { sha1sum "$T/$1.der" | cut -d' ' -f1 | tr 'a-f' 'A-F'; }
  fp256() { sha256sum "$T/$1.der" | cut -d' ' -f1; }
  certline() { printf 'CERT %s %s\n' "$(thumb "$1")" "$(base64 -w0 "$T/$1.der")"; }
  cp "$T/A.pem" "$T/bundle.pem"   # Linux already trusts A
  { certline A; certline B; printf 'DISALLOWED %s\n' "$(thumb C)"; echo 'END 2'; } >"$T/ca.out"
  : >"$ANCH/win-ca-Legacy_Root_CA-0123456789ABCDEF0123456789ABCDEF01234567.crt"
  reset_logs
  FAKE_PS_OUT="$T/ca.out" "$C" -q; rc=$?
  check "Two Windows PEMs: run succeeds" test "$rc" -eq 0
  check "Only the root Linux does not trust yet is imported (SHA-256 named)" \
    bash -c "[[ \$(find '$ANCH' -name 'omarchy-wsl-*.crt' | wc -l) -eq 1 && -f '$ANCH/omarchy-wsl-$(fp256 B).crt' ]]"
  check "Imported anchor is the exact DER Windows sent" \
    bash -c "openssl x509 -in '$ANCH/omarchy-wsl-$(fp256 B).crt' -outform DER | cmp -s - '$T/B.der'"
  check "Certificate in the Windows Disallowed store is never imported" test ! -e "$ANCH/omarchy-wsl-$(fp256 C).crt"
  check "Legacy win-ca-*.crt anchors from the old tool are pruned" bash -c "! compgen -G '$ANCH/win-ca-*' >/dev/null"
  check "Trust bundle rebuilt after a change" test -s "$LOG/update.calls"
  check "PowerShell reads LocalMachine\\Root only by default (no CA store, no CurrentUser\\Root)" \
    bash -c "grep -q 'includeUser = \$false' '$(ps_last)' && grep -q \"Cert:\\\\\\\\LocalMachine\\\\\\\\Root\" '$(ps_last)' && ! grep -q 'LocalMachine\\\\CA' '$(ps_last)'"
  check "PowerShell honours the Disallowed stores" grep -q 'Disallowed' "$(ps_last)"
  check "No Linux path is interpolated into PowerShell" bash -c "! grep -qE '/etc/|/run/|$T' '$(ps_last)'"
  pwsh_check "CA query PowerShell parses (pwsh)" "$(ps_last)"
  rm -f "$LOG/update.calls"
  FAKE_PS_OUT="$T/ca.out" "$C" -q; rc=$?
  check "Second run is a no-op (no trust rebuild)" bash -c "[[ $rc -eq 0 && ! -e '$LOG/update.calls' ]]"
  FAKE_PS_OUT="$T/ca.out" "$C" -q --include-user-store
  check "--include-user-store opts in to CurrentUser\\Root" grep -q 'includeUser = \$true' "$(ps_last)"
  rm -f "$ANCH"/omarchy-wsl-*.crt
  FAKE_PS_OUT="$T/ca.out" "$C" -q --thumbprint 0000000000000000000000000000000000000000
  check "--thumbprint allowlist: other roots are not imported" bash -c "! compgen -G '$ANCH/omarchy-wsl-*' >/dev/null"
  FAKE_PS_OUT="$T/ca.out" "$C" -q --thumbprint "$(thumb B)"
  check "--thumbprint allowlist: the listed root is imported" test -f "$ANCH/omarchy-wsl-$(fp256 B).crt"
  # Removed from Windows -> pruned.
  { certline A; echo 'END 1'; } >"$T/ca2.out"
  FAKE_PS_OUT="$T/ca2.out" "$C" -q
  check "Anchor removed from Windows is pruned" test ! -e "$ANCH/omarchy-wsl-$(fp256 B).crt"
  # Fail closed: incomplete or failed answers change nothing.
  FAKE_PS_OUT="$T/ca.out" "$C" -q
  { certline B; echo 'END 5'; } >"$T/ca3.out"
  FAKE_PS_OUT="$T/ca3.out" "$C" -q 2>/dev/null; rc=$?
  check "Truncated answer (END count mismatch): exit 1, nothing pruned" bash -c "[[ $rc -eq 1 && -f '$ANCH/omarchy-wsl-$(fp256 B).crt' ]]"
  FAKE_PS_RC=1 FAKE_PS_OUT=/dev/null "$C" -q 2>/dev/null; rc=$?
  check "Failed query: exit 1, nothing pruned" bash -c "[[ $rc -eq 1 && -f '$ANCH/omarchy-wsl-$(fp256 B).crt' ]]"
  { printf 'CERT %s %s\n' "$(thumb A)" "$(base64 -w0 "$T/B.der")"; echo 'END 1'; } >"$T/ca4.out"
  rm -f "$ANCH"/omarchy-wsl-*.crt
  FAKE_PS_OUT="$T/ca4.out" "$C" -q 2>/dev/null
  check "Thumbprint/DER mismatch is rejected" bash -c "! compgen -G '$ANCH/omarchy-wsl-*' >/dev/null"
  printf 'INCLUDE_USER_STORE=1\nTHUMBPRINTS=$(touch %s/pwned-ca)\n' "$T" >"$T/ca-sync.conf"
  FAKE_PS_OUT="$T/ca.out" "$C" -q 2>/dev/null
  check "Config file is parsed, never sourced" bash -c "[[ ! -e '$T/pwned-ca' ]]"
  rm -f "$T/ca-sync.conf"
else
  skip "openssl not installed: CA fixtures disabled"
fi

# =============================================================================
header "3. omarchy-dns-sync"
D="$BIN/omarchy-dns-sync"
RC="$T/etc/resolv.conf"
export OMARCHY_RESOLV_CONF="$RC" OMARCHY_DNS_RUN_DIR="$T/run-omarchy" OMARCHY_DNS_PERSIST_FILE="$T/etc/omarchy/wsl-upstream-dns.conf"
cat >"$T/fakebin/ip" <<EOF
#!/bin/sh
[ -n "\${FAKE_GW:-}" ] && echo "default via \$FAKE_GW dev eth0 proto kernel"
exit 0
EOF
chmod +x "$T/fakebin/ip"
export PATH="$T/fakebin:$PATH"
WSL_RC='# This file was automatically generated by WSL. To stop automatic generation of this file, add the following entry to /etc/wsl.conf:
# [network]
# generateResolvConf = false
nameserver 10.255.255.254
search corp.example'
printf '%s\n' "$WSL_RC" >"$RC"
cp "$RC" "$T/rc.before"
reset_logs
"$D" sync -q; rc=$?
check "Healthy WSL-generated resolv.conf is left byte-identical" bash -c "[[ $rc -eq 0 ]] && cmp -s '$T/rc.before' '$RC'"
check "No PowerShell call when resolv.conf is healthy" test "$(ps_count)" -eq 0
check "Last-known-good recorded in resolv.conf syntax" \
  bash -c "grep -qx 'nameserver 10.255.255.254' '$OMARCHY_DNS_PERSIST_FILE' && grep -qx 'search corp.example' '$OMARCHY_DNS_PERSIST_FILE'"
printf '# broken\n' >"$RC"
"$D" sync -q; rc=$?
check "Broken resolv.conf repaired from last-known-good" bash -c "[[ $rc -eq 0 ]] && grep -qx 'nameserver 10.255.255.254' '$RC'"
check "Search domains are written" grep -qx 'search corp.example' "$RC"
check "No public resolver is added by default" bash -c "! grep -Eq 'nameserver (1\\.1\\.1\\.1|8\\.8\\.8\\.8|9\\.9\\.9\\.9)' '$RC'"
check "No 'options rotate'" bash -c "! grep -q rotate '$RC'"
check "No 127.0.0.53 anywhere" bash -c "! grep -q '127.0.0.53' '$RC' '$D'"

rm -f "$OMARCHY_DNS_PERSIST_FILE" "$OMARCHY_DNS_RUN_DIR"/*
printf 'nameservers=($(touch %s/pwned-dns))\n' "$T" >"$OMARCHY_DNS_PERSIST_FILE"
printf 'NS 10.1.2.3\nNS fe80::1%%3\nNS fec0:0:0:ffff::1\nNS 1.1.1.1;rm\nNS $(touch %s/pwned-dns2)\nNS 2001:db8::53\nSEARCH ad.corp.example\nSEARCH bad domain\nEND\n' "$T" >"$T/dns.out"
printf '' >"$RC"
reset_logs
FAKE_PS_OUT="$T/dns.out" "$D" sync -q; rc=$?
check "Old-format state file is never sourced" bash -c "[[ ! -e '$T/pwned-dns' && ! -e '$T/pwned-dns2' ]]"
check "Windows DNS servers used when nothing local is known" bash -c "[[ $rc -eq 0 ]] && grep -qx 'nameserver 10.1.2.3' '$RC' && grep -qx 'nameserver 2001:db8::53' '$RC'"
check "Link-local, fec0:: and malformed nameservers are rejected" \
  bash -c "! grep -Eq 'fe80|fec0|rm|touch' '$RC' && [[ \$(grep -c '^nameserver' '$RC') -eq 2 ]]"
check "Windows DNS suffix written as search, invalid ones dropped" grep -qx 'search ad.corp.example' "$RC"
pwsh_check "DNS probe PowerShell parses (pwsh)" "$(ps_last)"

rm -f "$OMARCHY_DNS_PERSIST_FILE" "$OMARCHY_DNS_RUN_DIR"/*
printf '' >"$RC"
start=$SECONDS
FAKE_PS_SLEEP=30 OMARCHY_DNS_PS_TIMEOUT=1 FAKE_GW=172.16.5.1 "$D" sync -q 2>/dev/null; rc=$?
check "Hung PowerShell probe is bounded (gateway fallback in < 10 s)" \
  bash -c "[[ $rc -eq 0 ]] && (( $SECONDS - $start < 10 )) && grep -qx 'nameserver 172.16.5.1' '$RC'"
rm -f "$OMARCHY_DNS_PERSIST_FILE" "$OMARCHY_DNS_RUN_DIR"/*
printf '# empty\n' >"$RC"; cp "$RC" "$T/rc.before"
FAKE_PS_RC=1 FAKE_PS_OUT=/dev/null "$D" sync -q 2>/dev/null; rc=$?
check "Nothing discoverable: exit 1 and resolv.conf not replaced by an empty file" bash -c "[[ $rc -eq 1 ]] && cmp -s '$T/rc.before' '$RC'"
FAKE_PS_RC=1 FAKE_PS_OUT=/dev/null "$D" sync -q --public-fallback 2>/dev/null; rc=$?
check "--public-fallback is the only way to get public resolvers" bash -c "[[ $rc -eq 0 ]] && grep -qx 'nameserver 1.1.1.1' '$RC'"
ln -sfn /run/systemd/resolve/stub-resolv.conf "$T/etc/resolv-link.conf"
OMARCHY_RESOLV_CONF="$T/etc/resolv-link.conf" "$D" sync -q; rc=$?
check "Symlinked resolv.conf (opt-in resolver) is left alone" \
  bash -c "[[ $rc -eq 0 && \$(readlink '$T/etc/resolv-link.conf') == /run/systemd/resolve/stub-resolv.conf ]]"

U="$ROOT_DIR/wsl/systemd"
for unit in omarchy-dns-sync.service omarchy-proxy-sync.service; do
  check "$unit: not ordered after systemd-resolved, never before network-online" \
    bash -c "! grep -Eq '^(After|Wants|Before)=.*(systemd-resolved|network-online)' '$U/$unit'"
  check "$unit: TimeoutStartSec=10s" grep -qx 'TimeoutStartSec=10s' "$U/$unit"
  check "$unit: Documentation points at chntllh-labs/omarchy-wsl" grep -qx 'Documentation=https://github.com/chntllh-labs/omarchy-wsl' "$U/$unit"
done
if have systemd-analyze; then
  mkdir -p "$T/units"; cp "$U"/omarchy-*-sync.service "$T/units/"
  va=$(cd "$T/units" && systemd-analyze verify omarchy-dns-sync.service omarchy-proxy-sync.service 2>&1)
  check "systemd-analyze verify: no unknown keys in the sync units" bash -c "! grep -qi unknown <<<\"\$1\"" _ "$va"
else
  skip "systemd-analyze not installed"
fi

# =============================================================================
header "4. omarchy-mirror-sync"
M="$BIN/omarchy-mirror-sync"
ML="$T/etc/pacman.d/mirrorlist"
mkdir -p "$(dirname "$ML")"
export OMARCHY_MIRRORLIST="$ML" OMARCHY_MIRROR_TEMPLATES="$T/templates"
# Stub curl: latency per host from FAKE_CURL_OK ("host=seconds ..."); other
# hosts fail the way real curl does: -w still prints a time, then exit 6.
cat >"$T/fakebin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
host="${url#https://}"; host="${host%%/*}"
echo "$url" >>"${FAKE_CURL_LOG:-/dev/null}"
for kv in ${FAKE_CURL_OK:-}; do
  if [[ "${kv%%=*}" == "$host" ]]; then printf '%s\n' "${kv#*=}"; exit 0; fi
done
printf '0.004000\n'
exit 6
EOF
chmod +x "$T/fakebin/curl"
check "No dependency on bc" bash -c "! grep -qw bc '$M'"
printf 'Server = https://old.example/$repo/os/$arch\n' >"$ML"; cp "$ML" "$T/ml.before"
OMARCHY_MIRROR_ARCH=x86_64 "$M" rank 2>/dev/null; rc=$?
check "All probes fail: exit 1, mirrorlist byte-identical" bash -c "[[ $rc -eq 1 ]] && cmp -s '$T/ml.before' '$ML'"
check "All probes fail: never an empty list or a blank Server line" bash -c "grep -q '^Server = https://' '$ML' && ! grep -Eq '^Server[[:space:]]*=[[:space:]]*\$' '$ML'"
FAKE_CURL_LOG="$LOG/curl.urls" FAKE_CURL_OK="geo.mirror.pkgbuild.com=0.300 mirrors.kernel.org=0.050 stable-mirror.omarchy.org=0.900" \
  OMARCHY_MIRROR_ARCH=x86_64 "$M" rank 2>/dev/null; rc=$?
check "x86_64: Omarchy stable mirror pinned first, then by latency" \
  bash -c "[[ $rc -eq 0 ]] && [[ \"\$(grep '^Server' '$ML')\" == \"\$(printf 'Server = https://stable-mirror.omarchy.org/\$repo/os/\$arch\nServer = https://mirrors.kernel.org/archlinux/\$repo/os/\$arch\nServer = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch')\" ]]"
check "Failed mirrors are not listed" bash -c "! grep -q rackspace '$ML'"
check "Probes use HTTPS only (no plain http, no os.archlinuxarm.org)" bash -c "! grep -Eq '^http://|os\\.archlinuxarm\\.org' '$LOG/curl.urls'"
check "Previous list kept as mirrorlist.bak" cmp -s "$T/ml.before" "$ML.bak"
FAKE_CURL_OK="arm-stable-mirror.omarchy.org=0.700 de.mirror.archlinuxarm.org=0.100" OMARCHY_MIRROR_ARCH=aarch64 "$M" rank 2>/dev/null; rc=$?
check "aarch64: arm-stable-mirror.omarchy.org first" \
  bash -c "[[ $rc -eq 0 && \"\$(grep -m1 '^Server' '$ML')\" == 'Server = https://arm-stable-mirror.omarchy.org/\$arch/\$repo' ]]"
cat >"$T/fakebin/curl2" <<'EOF'
#!/usr/bin/env bash
printf '0.200\n0.300\n'
exit 0
EOF
chmod +x "$T/fakebin/curl2"; cp "$T/fakebin/curl2" "$T/fakebin2-curl"
mkdir -p "$T/fakebin2"; mv "$T/fakebin2-curl" "$T/fakebin2/curl"
PATH="$T/fakebin2:$PATH" OMARCHY_MIRROR_ARCH=x86_64 "$M" rank 2>/dev/null; rc=$?
check "Multi-line curl output: first line used, list still valid" \
  bash -c "[[ $rc -eq 0 ]] && ! grep -Eq '^Server[[:space:]]*=[[:space:]]*\$' '$ML' && grep -c '^Server = https://' '$ML' | grep -qv '^0\$'"
mkdir -p "$T/templates"
printf 'Server = http://os.archlinuxarm.org/$arch/$repo\nServer = \nServer = https://fl.us.mirror.archlinuxarm.org/$arch/$repo\n' >"$T/templates/mirrorlist.aarch64"
OMARCHY_MIRROR_ARCH=aarch64 "$M" restore-default 2>/dev/null; rc=$?
check "restore-default keeps only valid https Server lines from a template" \
  bash -c "[[ $rc -eq 0 && \"\$(grep '^Server' '$ML')\" == 'Server = https://fl.us.mirror.archlinuxarm.org/\$arch/\$repo' ]]"
printf 'Server = http://plain.example/$repo\n' >"$T/templates/mirrorlist.x86_64"
OMARCHY_MIRROR_ARCH=x86_64 "$M" restore-default 2>/dev/null; rc=$?
check "restore-default falls back to built-in https candidates" \
  bash -c "[[ $rc -eq 0 && \"\$(grep -m1 '^Server' '$ML')\" == 'Server = https://stable-mirror.omarchy.org/\$repo/os/\$arch' ]] && ! grep -q 'http://' '$ML'"

# =============================================================================
header "5. omarchy-netdoctor"
N="$BIN/omarchy-netdoctor"
R="$T/sysroot"
mkdir -p "$R/etc/pacman.d" "$R/etc/docker" "$R/proc/sys/fs/binfmt_misc" "$R/usr/lib/omarchy-wsl/bin"
printf '%s\n' "$WSL_RC" >"$R/etc/resolv.conf"
printf '[options]\nHoldPkg = pacman glibc\nArchitecture = auto\nDownloadUser = alpm\nSigLevel = Required DatabaseOptional\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n' >"$R/etc/pacman.conf"
printf 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch\n' >"$R/etc/pacman.d/mirrorlist"
cp "$ROOT_DIR/wsl/docker/daemon.json" "$R/etc/docker/daemon.json"
: >"$R/proc/sys/fs/binfmt_misc/WSLInterop"
: >"$R/usr/lib/omarchy-wsl/bin/powershell.exe"
mkdir -p "$T/ndbin"
for c in sysctl getent curl ping systemctl; do
  printf '#!/bin/sh\nexit 0\n' >"$T/ndbin/$c"; chmod +x "$T/ndbin/$c"
done
cat >"$T/ndbin/sysctl" <<'EOF'
#!/bin/sh
case "$2" in
  net.ipv4.ip_unprivileged_port_start) echo "${FAKE_PORT_START:-1024}" ;;
  net.ipv4.conf.all.rp_filter) echo 2 ;;
  net.ipv4.conf.all.route_localnet) echo 0 ;;
esac
EOF
printf '#!/bin/sh\necho "HTTP/2 200"\n' >"$T/ndbin/curl"
printf '#!/bin/sh\n[ "$1" = is-active ] && exit 3\nexit 0\n' >"$T/ndbin/systemctl"
chmod +x "$T/ndbin"/*
nd() { PATH="$T/ndbin:/usr/bin:/bin" OMARCHY_NETDOCTOR_ROOT="$R" NO_COLOR=1 "$N" "$@"; }
out=$(nd audit); rc=$?
check "Shipped configuration audits without failures (exit 0)" bash -c "[[ $rc -eq 0 ]]"
check "Sandbox-on pacman.conf (DownloadUser, no DisableSandbox) passes" grep -q 'PASS\] pacman download sandbox enabled (DownloadUser set)' <<<"$out"
check "Missing XferCommand is fine (built-in downloader)" grep -q 'PASS\] pacman uses its built-in downloader' <<<"$out"
check "DisableSandbox is never recommended" bash -c "! grep -q 'DisableSandbox missing' <<<\"\$1\"" _ "$out"
check "Shipped daemon.json raises no DNS warning" bash -c "! grep -q '127.0.0.53' <<<\"\$1\"" _ "$out"
npass=$(grep -c 'PASS\]' <<<"$out"); nwarn=$(grep -c 'WARN\]' <<<"$out"); nfail=$(grep -c 'FAIL\]' <<<"$out")
check "INFO lines are not counted as passed" grep -q "Checks: $((npass + nwarn + nfail))  (pass $npass, warn $nwarn, fail $nfail; INFO lines are not counted)" <<<"$out"
check "No address in Docker's default bridge subnet is printed" bash -c "! grep -qE '172\\.1[7]\\.' <<<\"\$1\"" _ "$out"
: >"$R/etc/pacman.d/mirrorlist"
out=$(nd audit); rc=$?
check "Empty mirrorlist: FAIL with a clean message (no '0\\n0' arithmetic error)" \
  bash -c "[[ $rc -eq 1 ]] && grep -q 'Mirrorlist has no usable Server line' <<<\"\$1\" && ! grep -q 'integer expression' <<<\"\$1\"" _ "$out"
printf 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch\n' >"$R/etc/pacman.d/mirrorlist"
out=$(FAKE_PORT_START=0 nd audit)
check "ip_unprivileged_port_start=0 is a WARN, not a PASS" grep -q 'WARN\] net.ipv4.ip_unprivileged_port_start = 0' <<<"$out"
mkdir -p "$T/repairbin"
for t in omarchy-dns-sync omarchy-ca-sync omarchy-proxy-sync omarchy-mirror-sync; do
  printf '#!/bin/sh\necho "%s $*" >>%s/repair.calls\nexit 0\n' "$t" "$LOG" >"$T/repairbin/$t"
  chmod +x "$T/repairbin/$t"
done
rm -f "$LOG/repair.calls"
out=$(PATH="$T/repairbin:$T/ndbin:/usr/bin:/bin" OMARCHY_NETDOCTOR_ROOT="$R" NO_COLOR=1 "$N" --repair 2>&1); rc=$?
check "--repair runs (no 'log: command not found', exit != 127)" bash -c "[[ $rc -ne 127 ]] && ! grep -q 'command not found' <<<\"\$1\"" _ "$out"
check "--repair runs dns, ca, proxy and mirror sync in order" \
  test "$(cat "$LOG/repair.calls" 2>/dev/null)" = "$(printf 'omarchy-dns-sync sync\nomarchy-ca-sync \nomarchy-proxy-sync \nomarchy-mirror-sync rank')"
check "--repair audits again afterwards" grep -q '=== Summary ===' <<<"$out"
nd --bogus >/dev/null 2>&1; rc=$?
check "Unknown option exits 2" test "$rc" -eq 2

echo
echo "Network Sync Suite: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed, ${TESTS_SKIPPED} skipped"
(( TESTS_FAILED == 0 )) || exit 1
if (( TESTS_SKIPPED > 0 )) && [[ "${OMW_STRICT:-0}" == 1 ]]; then exit 1; fi
exit 0
