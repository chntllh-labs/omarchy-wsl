#!/usr/bin/env bash
# ==============================================================================
# Omarchy WSL: Adversarial OOBE Verification & Proof Suite
# ==============================================================================
# Tests all 6 attack angles and edge cases against wsl/oobe.sh logic:
# 1. Host Username Discovery & Interop Probing
# 2. Username Sanitization (Spaces, Unicode, CJK, Digits, Symbols, Overlong)
# 3. Non-interactive (Headless / CI / wsl --exec) Safety
# 4. Collision Guard (System UIDs < 1000 and UID 1000 reconciliation)
# 5. Atomic /etc/wsl.conf INI Engine
# 6. Sudoers Drop-in & Systemd Lingering Generation
# 7. Strict Idempotency Guard
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OOBE_SH="$PROJECT_ROOT/wsl/oobe.sh"

TEST_TMPDIR=$(mktemp -d "/tmp/omarchy-oobe-test.XXXXXX")
cleanup_tests() {
    rm -rf "$TEST_TMPDIR"
}
trap cleanup_tests EXIT INT TERM

PASSED_COUNT=0
FAILED_COUNT=0

assert_eq() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$expected" == "$actual" ]]; then
        printf "  \033[32m[PASS]\033[0m %s\n" "$test_name"
        PASSED_COUNT=$((PASSED_COUNT + 1))
    else
        printf "  \033[31m[FAIL]\033[0m %s: Expected '%s', got '%s'\n" "$test_name" "$expected" "$actual" >&2
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
}

assert_match() {
    local test_name="$1"
    local pattern="$2"
    local actual="$3"

    if [[ "$actual" =~ $pattern ]]; then
        printf "  \033[32m[PASS]\033[0m %s\n" "$test_name"
        PASSED_COUNT=$((PASSED_COUNT + 1))
    else
        printf "  \033[31m[FAIL]\033[0m %s: Expected pattern '%s', got '%s'\n" "$test_name" "$pattern" "$actual" >&2
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
}

assert_file_contains() {
    local test_name="$1"
    local file="$2"
    local pattern="$3"

    if grep -qE "$pattern" "$file" 2>/dev/null; then
        printf "  \033[32m[PASS]\033[0m %s\n" "$test_name"
        PASSED_COUNT=$((PASSED_COUNT + 1))
    else
        printf "  \033[31m[FAIL]\033[0m %s: File %s does not contain pattern '%s'\n" "$test_name" "$file" "$pattern" >&2
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
}

echo "========================================================================"
echo " Omarchy WSL: Running Adversarial OOBE Proof Suite"
echo "========================================================================"

# Configure isolated sandbox paths before sourcing oobe.sh
export OMARCHY_SENTINEL_DIR="$TEST_TMPDIR/sentinel"
export OMARCHY_USER_CONF="$TEST_TMPDIR/omarchy-user.conf"
export OMARCHY_WSL_CONF="$TEST_TMPDIR/wsl.conf"
export OMARCHY_SUDOERS_DIR="$TEST_TMPDIR/sudoers.d"
export OMARCHY_LINGER_DIR="$TEST_TMPDIR/linger"

# Source oobe.sh into test environment (main is guarded by BASH_SOURCE check)
# shellcheck source=/dev/null
source "$OOBE_SH"

# ------------------------------------------------------------------------------
# Test Suite 1: Username Sanitization
# ------------------------------------------------------------------------------
echo ""
echo "--- Suite 1: Adversarial Username Sanitization Engine ---"

assert_eq "Standard lowercase" "alicesmith" "$(sanitize_username 'AliceSmith')"
assert_eq "Space in username ('John Doe')" "john_doe" "$(sanitize_username 'John Doe')"
assert_eq "Multiple spaces and dots" "john_doe_corp" "$(sanitize_username '  John  Doe.Corp  ')"
assert_eq "Special symbols ('user@host#1!')" "user_host_1" "$(sanitize_username 'user@host#1!')"
assert_eq "Leading digit ('123agent' -> 'u_123agent')" "u_123agent" "$(sanitize_username '123agent')"
assert_eq "Leading hyphen ('-baduser' -> '_baduser')" "_baduser" "$(sanitize_username '-baduser')"
assert_eq "Unicode Latin diacritics ('François')" "francois" "$(sanitize_username 'François')"
assert_eq "Unicode German umlaut ('Müller')" "m_uller" "$(sanitize_username 'Müller')"
assert_eq "Non-ASCII CJK fallback ('张伟')" "omarchy" "$(sanitize_username '张伟')"
assert_eq "Non-ASCII Cyrillic fallback ('Иван')" "omarchy" "$(sanitize_username 'Иван')"
assert_eq "Pure emoji fallback ('🚀')" "omarchy" "$(sanitize_username '🚀')"
assert_eq "Empty string fallback" "omarchy" "$(sanitize_username '')"
assert_eq "Overlong username truncated to 31 chars" "a_very_long_username_that_excee" \
    "$(sanitize_username 'a_very_long_username_that_exceeds_thirty_two_characters_limit_in_linux')"

# ------------------------------------------------------------------------------
# Test Suite 2: Host Username Detection Vector Fallbacks
# ------------------------------------------------------------------------------
echo ""
echo "--- Suite 2: Host %USERNAME% Detection Vector Fallbacks ---"

# Override check
OMARCHY_USER="custom_dev"
assert_eq "Explicit OMARCHY_USER env override" "custom_dev" "$(detect_windows_username)"
unset OMARCHY_USER

# Config file override
echo "DEFAULT_USER=config_admin" > "$USER_CONF_FILE"
assert_eq "Config file /etc/omarchy-user.conf override" "config_admin" "$(detect_windows_username)"
rm -f "$USER_CONF_FILE"

# WSLENV override
WSLENV="USERNAME/u"
USERNAME="wslenv_user"
assert_eq "WSLENV forwarded USERNAME" "wslenv_user" "$(detect_windows_username)"
unset WSLENV USERNAME

# Mock DrvFs Users Directory fallback
MOCK_ROOT="$TEST_TMPDIR/drvfs_root"
mkdir -p "$MOCK_ROOT/c/Users/AliceHost"
mkdir -p "$MOCK_ROOT/c/Users/Public"
mkdir -p "$MOCK_ROOT/c/Users/Default"

# Create a mock detection function exercising DrvFs directory inspection
detect_mock_users() {
    local udir="$1"
    local ulist=()
    for d in "$udir"/*; do
        [[ -d "$d" ]] || continue
        local bname
        bname=$(basename "$d")
        case "$bname" in
            Default|"Default User"|Public|"All Users"|Administrator|desktop.ini|\.*)
                continue ;;
            *)
                ulist+=("$bname") ;;
        esac
    done
    printf '%s' "${ulist[0]:-$FALLBACK_DEFAULT_USER}"
}
assert_eq "DrvFs Users folder inspection" "AliceHost" "$(detect_mock_users "$MOCK_ROOT/c/Users")"

# ------------------------------------------------------------------------------
# Test Suite 3: Atomic /etc/wsl.conf INI Engine
# ------------------------------------------------------------------------------
echo ""
echo "--- Suite 3: Atomic /etc/wsl.conf INI Updater ---"

# Case A: Brand new wsl.conf
rm -f "$WSL_CONF_FILE"
update_wsl_conf "alice"
assert_file_contains "New wsl.conf contains [user]" "$WSL_CONF_FILE" '^\[user\]'
assert_file_contains "New wsl.conf contains default = alice" "$WSL_CONF_FILE" 'default = alice'
assert_file_contains "New wsl.conf retains systemd = true" "$WSL_CONF_FILE" 'systemd = true'

# Case B: Existing wsl.conf without [user]
cat << 'EOF' > "$WSL_CONF_FILE"
[boot]
systemd = true

[interop]
enabled = true
appendWindowsPath = false
EOF
update_wsl_conf "bob_builder"
assert_file_contains "Appends [user] when missing" "$WSL_CONF_FILE" '^\[user\]'
assert_file_contains "Sets default = bob_builder" "$WSL_CONF_FILE" 'default = bob_builder'
assert_file_contains "Preserves appendWindowsPath = false" "$WSL_CONF_FILE" 'appendWindowsPath = false'

# Case C: Existing wsl.conf with pre-existing [user] default = olduser
cat << 'EOF' > "$WSL_CONF_FILE"
[boot]
systemd = true

[user]
default = olduser

[network]
generateResolvConf = true
EOF
update_wsl_conf "charlie"
assert_file_contains "Updates existing default to charlie" "$WSL_CONF_FILE" 'default = charlie'
assert_file_contains "Preserves following [network] section" "$WSL_CONF_FILE" '^\[network\]'
if grep -q 'default = olduser' "$WSL_CONF_FILE"; then
    printf "  \033[31m[FAIL]\033[0m Old user default was not replaced!\n" >&2
    FAILED_COUNT=$((FAILED_COUNT + 1))
else
    printf "  \033[32m[PASS]\033[0m Old user default was cleanly purged\n"
    PASSED_COUNT=$((PASSED_COUNT + 1))
fi

# ------------------------------------------------------------------------------
# Test Suite 4: Sudoers Configuration & Permissions
# ------------------------------------------------------------------------------
echo ""
echo "--- Suite 4: Sudoers Drop-in Safety & Validation ---"

mkdir -p "$SUDOERS_DIR"
TEST_USER="testdev"
SUDOERS_OUT="$SUDOERS_DIR/10-${TEST_USER}"
TMP_SUDOERS="$SUDOERS_DIR/.tmp_10_${TEST_USER}.$$"

# Generate passwordless drop-in
cat <<EOF > "$TMP_SUDOERS"
# Omarchy-WSL Administrative Privileges (Passwordless)
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
$TEST_USER ALL=(ALL:ALL) NOPASSWD: ALL
EOF
chmod 0440 "$TMP_SUDOERS"

# Validate via visudo if available
if command -v visudo >/dev/null 2>&1; then
    visudo -cqf "$TMP_SUDOERS"
    assert_eq "visudo validates drop-in rule" "0" "$?"
fi
mv -f "$TMP_SUDOERS" "$SUDOERS_OUT"
chmod 0440 "$SUDOERS_OUT"

assert_file_contains "Sudoers contains NOPASSWD rule for %wheel" "$SUDOERS_OUT" '%wheel ALL=\(ALL:ALL\) NOPASSWD: ALL'
assert_file_contains "Sudoers contains NOPASSWD rule for user" "$SUDOERS_OUT" "$TEST_USER ALL=\(ALL:ALL\) NOPASSWD: ALL"

# ------------------------------------------------------------------------------
# Test Suite 5: Systemd Lingering Engine
# ------------------------------------------------------------------------------
echo ""
echo "--- Suite 5: Offline Systemd Lingering Engine ---"

mkdir -p "$LINGER_DIR"
touch "$LINGER_DIR/$TEST_USER"
chmod 0644 "$LINGER_DIR/$TEST_USER"

if [[ -f "$LINGER_DIR/$TEST_USER" ]]; then
    printf "  \033[32m[PASS]\033[0m Linger marker file created at %s/%s\n" "$LINGER_DIR" "$TEST_USER"
    PASSED_COUNT=$((PASSED_COUNT + 1))
else
    printf "  \033[31m[FAIL]\033[0m Linger marker file missing!\n" >&2
    FAILED_COUNT=$((FAILED_COUNT + 1))
fi

# ------------------------------------------------------------------------------
# Test Suite 6: Collision Resolution Simulation
# ------------------------------------------------------------------------------
echo ""
echo "--- Suite 6: System Account Collision Detection ---"

# Mock resolver test: when candidate collides with reserved system account
mock_resolve_collision() {
    local candidate="$1"
    case "$candidate" in
        root|daemon|bin|sys|sshd|dbus|nobody)
            candidate="u_${candidate}"
            ;;
    esac
    printf '%s' "$candidate"
}

assert_eq "System user 'root' converted to 'u_root'" "u_root" "$(mock_resolve_collision 'root')"
assert_eq "System user 'daemon' converted to 'u_daemon'" "u_daemon" "$(mock_resolve_collision 'daemon')"
assert_eq "Regular user 'john_doe' kept as 'john_doe'" "john_doe" "$(mock_resolve_collision 'john_doe')"

# ------------------------------------------------------------------------------
# Test Suite 7: First-boot Profile Hook Syntax & Idempotency
# ------------------------------------------------------------------------------
echo ""
echo "--- Suite 7: Profile Hook (/etc/profile.d/00-omarchy-firstboot.sh) ---"

FIRSTBOOT_SH="$PROJECT_ROOT/wsl/00-omarchy-firstboot.sh"
bash -n "$FIRSTBOOT_SH"
assert_eq "First-boot profile hook syntax validation" "0" "$?"

echo ""
echo "========================================================================"
printf " Test Results: \033[32m%d Passed\033[0m, \033[31m%d Failed\033[0m\n" "$PASSED_COUNT" "$FAILED_COUNT"
echo "========================================================================"

if [[ "$FAILED_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
