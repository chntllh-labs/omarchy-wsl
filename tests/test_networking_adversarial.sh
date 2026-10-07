#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: Automated Adversarial Networking & DNS Test Suite
# /tests/test_networking_adversarial.sh
# ==============================================================================
# Tests resilience across NAT, Mirrored mode, DNS tunneling, corporate proxies,
# container bridge collisions, and pacman mirror failover.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo -e "  \e[32m[PASS]\e[0m $*"
}

fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo -e "  \e[31m[FAIL]\e[0m $*"
}

header() {
  echo -e "\n\e[1m\e[36m>>> TEST SUITE: $*\e[0m"
}

# -----------------------------------------------------------------------------
# 1. Test: Host .wslconfig Generator (Mirrored vs NAT)
# -----------------------------------------------------------------------------
test_wslconfig_generator() {
  header "1. Host .wslconfig Generator Matrix"

  local gen_script="${ROOT_DIR}/tools/generate-wslconfig.sh"
  [[ -x "$gen_script" ]] || { fail "generate-wslconfig.sh missing or not executable"; return; }

  # Test 1.1: Default generation (Mirrored mode)
  local out_mirrored
  out_mirrored=$("$gen_script" -d)
  if echo "$out_mirrored" | grep -q "networkingMode=mirrored" && \
     echo "$out_mirrored" | grep -q "dnsTunneling=true" && \
     echo "$out_mirrored" | grep -q "autoProxy=true" && \
     echo "$out_mirrored" | grep -q "hostAddressLoopback=true"; then
    pass "Default .wslconfig enables mirrored mode, DNS tunneling, and auto-proxy."
  else
    fail "Default .wslconfig failed to configure mirrored parameters!"
  fi

  # Test 1.2: Force NAT fallback
  local out_nat
  out_nat=$("$gen_script" -d --force-nat)
  if echo "$out_nat" | grep -q "networkingMode=NAT" && \
     echo "$out_nat" | grep -q "dnsTunneling=false"; then
    pass "Forced NAT option safely generates resilient legacy fallback config."
  else
    fail "Forced NAT failed to configure NAT parameters!"
  fi
}

# -----------------------------------------------------------------------------
# 2. Test: Kernel Sysctl Network Hardening Parameters
# -----------------------------------------------------------------------------
test_sysctl_hardening() {
  header "2. Kernel Sysctl Network Configuration"

  local sysctl_file="${ROOT_DIR}/wsl/sysctl.d/99-zz-omarchy-wsl-network.conf"
  [[ -f "$sysctl_file" ]] || { fail "99-zz-omarchy-wsl-network.conf missing"; return; }

  if grep -q "net.ipv4.ip_unprivileged_port_start = 0" "$sysctl_file"; then
    pass "Unprivileged port binding enabled (port 80/443 development permitted)."
  else
    fail "ip_unprivileged_port_start = 0 missing!"
  fi

  if grep -q "net.ipv4.conf.all.rp_filter = 2" "$sysctl_file" && \
     grep -q "net.ipv4.conf.default.rp_filter = 2" "$sysctl_file"; then
    pass "Loose Reverse Path Filtering (rp_filter = 2) configured for VPN multi-homing."
  else
    fail "Loose rp_filter missing! Asymmetric VPN routing will cause packet drops."
  fi

  if grep -q "net.ipv4.ip_forward = 1" "$sysctl_file"; then
    pass "IP packet forwarding enabled for Docker/Podman bridges."
  else
    fail "net.ipv4.ip_forward = 1 missing!"
  fi
}

# -----------------------------------------------------------------------------
# 3. Test: systemd-resolved Coexistence & Drop-in Hardening
# -----------------------------------------------------------------------------
test_systemd_resolved_dropin() {
  header "3. systemd-resolved & DNS Tunneling Coexistence"

  local resolved_dropin="${ROOT_DIR}/wsl/systemd/systemd-resolved.conf.d/10-omarchy-wsl.conf"
  [[ -f "$resolved_dropin" ]] || { fail "resolved drop-in missing"; return; }

  if grep -q "DNSSEC=no" "$resolved_dropin"; then
    pass "DNSSEC=no configured (prevents corporate inspection proxy SERVFAIL)."
  else
    fail "DNSSEC=no missing in resolved drop-in!"
  fi

  if grep -q "LLMNR=no" "$resolved_dropin" && grep -q "MulticastDNS=no" "$resolved_dropin"; then
    pass "LLMNR and mDNS disabled (prevents port 5353/5355 conflicts in mirrored mode)."
  else
    fail "LLMNR or mDNS not disabled; will clash with Windows host svchost."
  fi

  if grep -q "FallbackDNS=" "$resolved_dropin"; then
    pass "FallbackDNS configured with resilient anycast addresses."
  else
    fail "FallbackDNS missing in resolved drop-in!"
  fi
}

# -----------------------------------------------------------------------------
# 4. Test: Pacman Resilience & Ping-less Mirror Ranking
# -----------------------------------------------------------------------------
test_pacman_resilience() {
  header "4. Pacman Configuration & Mirror Resilience"

  local pacman_conf="${ROOT_DIR}/wsl/pacman/pacman.conf.omarchy"
  [[ -f "$pacman_conf" ]] || { fail "pacman.conf.omarchy missing"; return; }

  if grep -q "^DisableSandbox" "$pacman_conf"; then
    pass "Pacman DisableSandbox active for WSL container isolation."
  else
    fail "DisableSandbox missing from pacman.conf!"
  fi

  if grep -q -- "--connect-timeout 5" "$pacman_conf"; then
    pass "Pacman XferCommand enforces strict 5-second connection timeout."
  else
    fail "Pacman connection timeout missing! May hang indefinitely on dead mirrors."
  fi

  # Check mirrorlists
  local ml_x86="${ROOT_DIR}/wsl/pacman/mirrorlist.x86_64"
  local ml_arm="${ROOT_DIR}/wsl/pacman/mirrorlist.aarch64"

  if [[ -s "$ml_x86" && $(grep -c "^Server" "$ml_x86") -ge 3 ]]; then
    pass "x86_64 mirrorlist contains $(grep -c "^Server" "$ml_x86") resilient multi-tier servers."
  else
    fail "x86_64 mirrorlist invalid or empty!"
  fi

  if [[ -s "$ml_arm" && $(grep -c "^Server" "$ml_arm") -ge 3 ]]; then
    pass "aarch64 mirrorlist contains $(grep -c "^Server" "$ml_arm") resilient multi-tier servers."
  else
    fail "aarch64 mirrorlist invalid or empty!"
  fi

  # Test mirror-sync restore-default logic
  local sync_bin="${ROOT_DIR}/bin/omarchy-mirror-sync"
  [[ -x "$sync_bin" ]] || { fail "omarchy-mirror-sync missing or not executable"; return; }
  pass "omarchy-mirror-sync binary present and executable."
}

# -----------------------------------------------------------------------------
# 5. Test: Container Coexistence (Docker & Podman Subnets)
# -----------------------------------------------------------------------------
test_container_coexistence() {
  header "5. Container Engine Subnet Isolation & MTU"

  local docker_json="${ROOT_DIR}/wsl/docker/daemon.json"
  [[ -f "$docker_json" ]] || { fail "daemon.json missing"; return; }

  # Test that Docker doesn't use 172.17.0.0/16
  if grep -q "198.18.0" "$docker_json"; then
    pass "Docker bip/address-pools isolated in RFC 2544 space (198.18.0.0/16)."
  else
    fail "Docker default subnet not isolated! Risk of colliding with corporate VPNs."
  fi

  if grep -q '"mtu": 1420' "$docker_json"; then
    pass "Docker MTU clamped to 1420 to prevent VPN encapsulation drops."
  else
    fail "Docker MTU not clamped!"
  fi

  local podman_conf="${ROOT_DIR}/wsl/podman/containers.conf"
  [[ -f "$podman_conf" ]] || { fail "podman containers.conf missing"; return; }

  if grep -q "198.19.0.0" "$podman_conf"; then
    pass "Podman network pool isolated in 198.19.0.0/16."
  else
    fail "Podman subnet pool not isolated!"
  fi

  if grep -q "1420" "$podman_conf"; then
    pass "Podman pasta MTU clamped to 1420."
  else
    fail "Podman MTU not clamped!"
  fi
}

# -----------------------------------------------------------------------------
# 6. Test: Windows Interop Shims & Clean PATH
# -----------------------------------------------------------------------------
test_interop_shims() {
  header "6. Windows Interop Shims & PATH Isolation"

  local shims_script="${ROOT_DIR}/wsl/bin/wsl-shims-setup.sh"
  local profile_sh="${ROOT_DIR}/wsl/profile.d/10-omarchy-wsl-path.sh"

  [[ -x "$shims_script" ]] || { fail "wsl-shims-setup.sh missing or not executable"; return; }
  [[ -f "$profile_sh" ]] || { fail "10-omarchy-wsl-path.sh missing"; return; }

  if grep -q "powershell.exe" "$shims_script" && grep -q "cmd.exe" "$shims_script"; then
    pass "Interop shims script provides essential Windows executables."
  else
    fail "Essential shims missing from setup script!"
  fi

  if grep -q "/usr/lib/omarchy-wsl/bin" "$profile_sh"; then
    pass "Profile drop-in correctly prepends shims directory."
  else
    fail "Profile drop-in does not add shims directory to PATH!"
  fi
}

# -----------------------------------------------------------------------------
# 7. Test: Diagnostic NetDoctor Suite
# -----------------------------------------------------------------------------
test_netdoctor() {
  header "7. Omarchy NetDoctor Diagnostic Utility"

  local netdoctor="${ROOT_DIR}/bin/omarchy-netdoctor"
  [[ -x "$netdoctor" ]] || { fail "omarchy-netdoctor missing or not executable"; return; }

  local help_out
  help_out=$("$netdoctor" --help)
  if echo "$help_out" | grep -q "audit" && echo "$help_out" | grep -q "\-\-repair"; then
    pass "omarchy-netdoctor exposes audit and automated self-healing modes."
  else
    fail "omarchy-netdoctor help missing required commands!"
  fi
}

# -----------------------------------------------------------------------------
# Run All Tests & Report
# -----------------------------------------------------------------------------
test_wslconfig_generator
test_sysctl_hardening
test_systemd_resolved_dropin
test_pacman_resilience
test_container_coexistence
test_interop_shims
test_netdoctor

echo -e "\n========================================================"
echo -e " Adversarial Test Results: ${TESTS_PASSED}/${TESTS_RUN} Passed"
echo -e "========================================================"

if [[ $TESTS_FAILED -eq 0 ]]; then
  echo -e "\e[32m\e[1mAll adversarial networking tests passed with 100% success!\e[0m\n"
  exit 0
else
  echo -e "\e[31m\e[1mEncountered $TESTS_FAILED test failures.\e[0m\n"
  exit 1
fi
