#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: Networking & DNS Configuration Test Suite
# tests/test_networking_adversarial.sh
# ==============================================================================
# Shipped networking configuration: the .wslconfig generator (run under pwsh),
# sysctl drop-ins (validated against the running kernel's /proc/sys), the
# resolver model (systemd-resolved masked, WSL-generated resolv.conf, dormant
# resolved drop-in), container engine configs and the shims/PATH wiring.
# Behaviour of the sync tools themselves is covered by tests/test_network_sync.sh.
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

T=$(mktemp -d "${TMPDIR:-/tmp}/omw-netcfg.XXXXXX")
# shellcheck disable=SC2317  # invoked by the EXIT trap
cleanup() { rm -rf "$T"; }
trap cleanup EXIT
PWSH="${PWSH:-$(command -v pwsh || true)}"

# -----------------------------------------------------------------------------
test_wslconfig_generator() {
  header "1. .wslconfig generator (tools/generate-wslconfig.ps1, run under pwsh)"
  local gen="$ROOT_DIR/tools/generate-wslconfig.ps1" out
  if [[ -z "$PWSH" ]]; then skip "pwsh not installed: generator not run"; return; fi
  out=$(cd "$T" && "$PWSH" -NoLogo -NoProfile -File "$gen" -DryRun -Quiet -HostMemoryGB 64 \
        -HostLogicalProcessors 16 -HostArch arm64 -HostBuild 26100 -WslConfigPath "$T/a.wslconfig" 2>&1 | tr -d '\r')
  section_of() { awk -v k="$1" '/^\[/ { s = $0; next } index($0, k "=") == 1 { print s; exit }' <<<"$2"; }
  check "Windows 11: mirrored networking, DNS tunneling and autoProxy" \
    bash -c "grep -qx 'networkingMode=mirrored' <<<\"\$1\" && grep -qx 'dnsTunneling=true' <<<\"\$1\" && grep -qx 'autoProxy=true' <<<\"\$1\"" _ "$out"
  check "hostAddressLoopback is written under [experimental]" test "$(section_of hostAddressLoopback "$out")" = "[experimental]"
  check "networkingMode is written under [wsl2]" test "$(section_of networkingMode "$out")" = "[wsl2]"
  out=$(cd "$T" && "$PWSH" -NoLogo -NoProfile -File "$gen" -DryRun -Quiet -ForceNAT -HostMemoryGB 16 \
        -HostLogicalProcessors 8 -HostArch x64 -HostBuild 19045 -WslConfigPath "$T/b.wslconfig" 2>&1 | tr -d '\r')
  check "-ForceNAT: NAT without DNS tunneling" \
    bash -c "grep -qx 'networkingMode=NAT' <<<\"\$1\" && grep -qx 'dnsTunneling=false' <<<\"\$1\"" _ "$out"
}

# -----------------------------------------------------------------------------
test_sysctl() {
  header "2. Kernel sysctl drop-ins"
  local net="$ROOT_DIR/wsl/sysctl.d/99-zz-omarchy-wsl-network.conf" f key bad=0 missing=0
  check "Privileged ports stay privileged (ip_unprivileged_port_start = 1024)" \
    grep -qx 'net.ipv4.ip_unprivileged_port_start = 1024' "$net"
  check "route_localnet is not enabled" bash -c "! grep -Eq '^[^#]*route_localnet[[:space:]]*=[[:space:]]*1' '$net'"
  check "IPv6 forwarding is not enabled (keeps router advertisements working)" \
    bash -c "! grep -Eq '^[^#]*ipv6\\.conf\\.all\\.forwarding[[:space:]]*=[[:space:]]*1' '$net'"
  check "IPv4 forwarding is left to the container engines" bash -c "! grep -Eq '^[^#]*net\\.ipv4\\.ip_forward[[:space:]]*=' '$net'"
  check "Loose reverse-path filtering (rp_filter = 2)" \
    bash -c "grep -qx 'net.ipv4.conf.all.rp_filter = 2' '$net' && grep -qx 'net.ipv4.conf.default.rp_filter = 2' '$net'"
  check "Stability sysctls live in wsl/sysctl.d (installed with the others)" \
    bash -c "[[ -f '$ROOT_DIR/wsl/sysctl.d/99-zz-omarchy-wsl-stability.conf' && ! -e '$ROOT_DIR/wsl/99-zz-omarchy-wsl-stability.conf' ]]"
  check "vm.vfs_cache_pressure stays 100" grep -qx 'vm.vfs_cache_pressure = 100' "$ROOT_DIR/wsl/sysctl.d/99-zz-omarchy-wsl-stability.conf"
  for f in "$ROOT_DIR"/wsl/sysctl.d/*.conf; do
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
      if ! [[ "$line" =~ ^([a-z0-9_.-]+)\ =\ [0-9-]+$ ]]; then bad=1; echo "      bad line in ${f##*/}: $line"; continue; fi
      key="${BASH_REMATCH[1]}"
      if [[ -d /proc/sys/net ]] && [[ ! -e "/proc/sys/${key//.//}" ]]; then missing=1; echo "      unknown key: $key"; fi
    done <"$f"
  done
  check "Every sysctl line is 'key = integer'" test "$bad" -eq 0
  if [[ -d /proc/sys/net ]]; then
    check "Every sysctl key exists in the running kernel" test "$missing" -eq 0
  else
    skip "/proc/sys not available: key existence not checked"
  fi
}

# -----------------------------------------------------------------------------
test_resolver_model() {
  header "3. Resolver model (resolved masked, WSL writes resolv.conf)"
  local dropin="$ROOT_DIR/wsl/systemd/systemd-resolved.conf.d/10-omarchy-wsl.conf"
  check "wsl.conf keeps generateResolvConf = true" grep -qx 'generateResolvConf = true' "$ROOT_DIR/wsl/wsl.conf"
  check "Resolved drop-in is labelled dormant / opt-in" grep -q 'DORMANT, opt-in only' "$dropin"
  check "Resolved drop-in: DNSSEC, LLMNR and mDNS off" \
    bash -c "grep -qx 'DNSSEC=no' '$dropin' && grep -qx 'LLMNR=no' '$dropin' && grep -qx 'MulticastDNS=no' '$dropin'"
  check "Resolved drop-in adds no public FallbackDNS" grep -qx 'FallbackDNS=' "$dropin"
  check "No loopback stub resolver address in shipped network files" \
    bash -c "! grep -rl '127\\.0\\.0\\.53' '$ROOT_DIR/wsl/docker' '$ROOT_DIR/wsl/podman' '$ROOT_DIR/bin/omarchy-dns-sync' '$ROOT_DIR/wsl/systemd'"
  check "dns-sync never appends public resolvers by default" grep -q -- '--public-fallback' "$ROOT_DIR/bin/omarchy-dns-sync"
}

# -----------------------------------------------------------------------------
test_pacman() {
  header "4. pacman mirrors"
  local ms="$ROOT_DIR/bin/omarchy-mirror-sync"
  check "omarchy-mirror-sync is executable" test -x "$ms"
  check "Mirror candidates are HTTPS only" bash -c "! sed -n '/^get_candidates/,/^}/p' '$ms' | grep -q 'http://'"
  check "Omarchy stable mirrors are the first candidates" \
    bash -c "grep -q 'https://stable-mirror.omarchy.org/\$repo/os/\$arch' '$ms' && grep -q 'https://arm-stable-mirror.omarchy.org/\$arch/\$repo' '$ms'"
}

# -----------------------------------------------------------------------------
test_containers() {
  header "5. Container engines (subnets, MTU, DNS)"
  local dj="$ROOT_DIR/wsl/docker/daemon.json" pc="$ROOT_DIR/wsl/podman/containers.conf"
  check "daemon.json is valid JSON" python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$dj"
  check "Docker pools in RFC 2544 space (198.18.0.0/16), MTU 1420" \
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["default-address-pools"][0]["base"]=="198.18.0.0/16" and d["mtu"]==1420' "$dj"
  check "Docker gets no hard-coded DNS (inherits WSL's resolv.conf)" \
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "dns" not in d' "$dj"
  check "containers.conf is valid TOML" python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$pc"
  check "Podman subnet 198.19.0.0/16 and pasta MTU 1420" \
    python3 -c 'import sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb"))["network"]; assert d["default_subnet"]=="198.19.0.0/16" and d["pasta_options"]==["-m","1420"]' "$pc"
  check "No automatic publishing of every container port, no dns_bind_port=0" \
    bash -c "! grep -Eq 'tcp-ports|udp-ports|dns_bind_port' '$pc'"
  check "No literal from Docker's default bridge subnet in shipped files" \
    bash -c "! grep -rEq '172\\.1[7]\\.' '$ROOT_DIR/wsl/docker' '$ROOT_DIR/wsl/podman' '$ROOT_DIR/bin/omarchy-netdoctor' '$ROOT_DIR/docs/WSL-NETWORKING-AND-DNS-ADVERSARIAL-REVIEW.md'"
}

# -----------------------------------------------------------------------------
test_shims_path() {
  header "6. Windows shims & PATH"
  local shims="$ROOT_DIR/wsl/bin/wsl-shims-setup.sh" profile="$ROOT_DIR/wsl/profile.d/10-omarchy-wsl-path.sh"
  check "Shims script links powershell.exe and cmd.exe" bash -c "grep -q 'powershell.exe' '$shims' && grep -q 'cmd.exe' '$shims'"
  check "Shims script never searches with -maxdepth 5 (wt.exe is at depth 6)" bash -c "! grep -q 'maxdepth 5' '$shims'"
  check "profile.d appends the curated shim directory" grep -q '/usr/lib/omarchy-wsl/bin' "$profile"
}

# -----------------------------------------------------------------------------
test_netdoctor() {
  header "7. omarchy-netdoctor"
  local nd="$ROOT_DIR/bin/omarchy-netdoctor" out rc
  out=$("$nd" --help); rc=$?
  check "--help exits 0 and documents audit + --repair" \
    bash -c "[[ $rc -eq 0 ]] && grep -q audit <<<\"\$1\" && grep -q -- '--repair' <<<\"\$1\"" _ "$out"
  check "netdoctor never recommends DisableSandbox" bash -c "! grep -q 'DisableSandbox missing' '$nd'"
}

test_wslconfig_generator
test_sysctl
test_resolver_model
test_pacman
test_containers
test_shims_path
test_netdoctor

echo
echo "Networking Adversarial Suite: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed, ${TESTS_SKIPPED} skipped"
(( TESTS_FAILED == 0 )) || exit 1
if (( TESTS_SKIPPED > 0 )) && [[ "${OMW_STRICT:-0}" == 1 ]]; then exit 1; fi
exit 0
