# Omarchy-WSL: First-Launch OOBE & Owner Account Specification

**Version:** 2.0.0 (`wsl/oobe.sh` reports `omarchy-oobe 2.0.0`)
**Scope:** how the distro owner (uid 1000) is created on first launch, how it is
kept consistent afterwards, and how it is renamed. Every statement below is
implemented in the files listed in section 12 and exercised by the suites in
section 13. Statements about real WSL behaviour that no test covers are marked
**(unverified)**.

---

## 1. Entry points

| How the distro starts | What runs the OOBE |
|---|---|
| `.wsl` package (`wsl --install --from-file`, double-click, Store) | WSL runs `[oobe] command = /usr/lib/wsl/oobe.sh` from `/etc/wsl-distribution.conf` as root on first launch, then starts `defaultUid = 1000`. A non-zero exit means the OOBE runs again on the next launch **(unverified: WSL re-run semantics)**. |
| `wsl --import` (WSL skips `[oobe]`) | `/etc/profile.d/00-omarchy-firstboot.sh` runs the OOBE from the first interactive root login shell, then `exec runuser -u <owner> -- bash -l` (section 10). |
| Image tests / CI | `/usr/lib/wsl/oobe.sh --headless --user devuser` inside a container with no systemd, no terminal and no Windows interop. It must exit 0. |

`/usr/lib/omarchy-wsl/oobe.sh` is a compatibility symlink to `/usr/lib/wsl/oobe.sh`.
The OOBE resolves its shared library in this order: `$OMARCHY_WSL_LIB_DIR`,
`<script dir>/../lib/omarchy-wsl-account.sh` (repository), `<script dir>/../omarchy-wsl/account.sh`,
then `/usr/lib/omarchy-wsl/account.sh`.

## 2. Identity model

* **The owner is whoever holds uid 1000** (`getent passwd 1000`). Names recorded in
  the sentinel or in `/etc/omarchy-user.conf` are informational. They never
  decide who the owner is and are never used to rename anyone.
* **An existing uid 1000 is never renamed by the OOBE and its processes are never
  killed** (no `usermod -l`, no `pkill`). Renames are the job of
  `omarchy-rename-owner` (section 11).
* WSL's `defaultUid = 1000` and the DrvFs `uid=1000,gid=1000` automount options are
  number-based, so they survive a rename.

## 3. Command line

```
oobe.sh [-u|--user NAME] [--headless] [--require-password] [--password-stdin]
        [--sync-network] [--force] [-h|--help] [--version]
```

| Option | Behaviour |
|---|---|
| `-u, --user NAME` (`--user=NAME`) | Owner name, **strict**: it must already be valid (section 6). It is never transliterated. `OMARCHY_USER=NAME` in the environment is equivalent. |
| `--headless` (`--unattended`, `--non-interactive`) | Never prompt. |
| `--require-password` | sudo asks for the owner's password. Interactive runs refuse an empty password. Headless runs lock the password unless `--password-stdin` is given, and print how to set one (`wsl.exe -d <distro> -u root -- passwd <owner>`). |
| `--password-stdin` | Read the owner's password from the first line of stdin and set it with `chpasswd` (on stdin, never on argv). An empty line exits 2. |
| `--sync-network` | Also run `omarchy-dns-sync sync`, `omarchy-ca-sync` and `omarchy-proxy-sync`, each under `timeout` (20 s). By default they are not run: their systemd units run them at boot. |
| `--force` | For an already provisioned owner: re-apply groups, sudoers, linger, `wsl.conf`, home scaffolding, user environment, shims and the state files. It never renames, never touches the password and never purges history. |
| `-h, --help` / `--version` | Print to stdout and exit 0. These work without root. |

Unknown options, positional arguments and `--user` without a value exit **2**,
with the usage on stderr.

**Exit codes:** `0` provisioned, or already provisioned (no-op) · `1` failure ·
`2` usage or invalid `--user` · `3` precondition (not root, uid 1000 already belongs
to a different name than `--user`, the name collides with an existing user or group,
or the home path is held by another uid) · `75` another OOBE or
`omarchy-rename-owner` holds the lock · `128+n` interrupted by signal *n* (129 HUP,
130 INT, 143 TERM). An interrupted OOBE never exits 0 and never writes the sentinel.

## 4. Flow

1. Parse arguments; refuse non-root with exit 3 and the hint
   `wsl.exe -d <distro> -u root -- /usr/lib/wsl/oobe.sh`.
2. Install traps. `EXIT` removes temp files and keeps `$?`. `INT`/`TERM`/`HUP`
   remove temp files, restore terminal settings and `exit 128+n`.
3. Decide interactivity (section 5).
4. Take the account lock: `flock -n` on `/run/omarchy/account.lock`, falling back
   to `/var/lib/omarchy/.account.lock` when `/run` is unusable. Busy means exit 75.
   The same lock is used by `omarchy-rename-owner`.
5. Decide the mode from `getent passwd 1000` and the sentinel:

   | uid 1000 | sentinel (`PROVISIONED_UID=1000`) | `--user` | Result |
   |---|---|---|---|
   | exists | any | different name | exit 3, pointing to `omarchy-rename-owner NAME` |
   | exists | present | absent or same | **no-op, exit 0** (a warning if the sentinel records another name) |
   | exists | present, `--force` | absent or same | mode `force` |
   | exists | absent | absent or same | mode `adopt`: the existing account is kept as the owner |
   | absent | any | any | mode `create` (a warning if a stale sentinel exists) |

6. `create` only: choose the name (section 6).
7. Run `/usr/lib/omarchy-wsl/pacman-init.sh` when executable, under `timeout` 300 s.
   Failure is a warning.
8. `--sync-network` only: the three sync tools, 20 s each, failures are warnings.
9. `create` only: create the primary group, then `useradd -m -u 1000 -g <name> -s /bin/bash -d /home/<name> -k /etc/skel <name>` (section 7).
10. Groups: `usermod -aG` with whichever of `wheel docker video render input audio` exist.
11. Password (section 8).
12. Sudoers (section 8). A validation failure exits 1; a missing `visudo` is a warning.
13. Linger (section 9). Failure is a warning.
14. `/etc/wsl.conf` `[user] default = <owner>` (section 9). Failure exits 1.
15. Home scaffolding and the Omarchy user environment (section 9).
16. Windows tool shims (section 9). They never affect the exit status.
17. `/etc/omarchy-user.conf`, then the sentinel, both atomic (section 9). Failure exits 1.
    The sentinel is written last.

## 5. Terminals and headless operation

* Prompts and interactive output use the controlling terminal only: fd 3 reads
  `/dev/tty` and fd 4 writes `/dev/tty`. Nothing is ever prompted through stdout or
  inside `$(...)`, and answers are returned in variables.
* The OOBE runs **headless** when `--headless` is given, when `CI=true` or
  `DEBIAN_FRONTEND=noninteractive`, when `SSH_CONNECTION` or `SSH_TTY` is set and no
  `--user` was given, or when `/dev/tty` cannot be opened (an existing node is not
  enough). It never blocks on input in headless mode.
* Every external helper is bounded by `timeout`: keyring init 300 s, nvim setup
  300 s, theme 120 s, mise 30 s, scaffold `mkdir` 10 s, sync tools 20 s, shims 30 s,
  Windows `cmd.exe` 5 s, `loginctl` 15 s. Long-lived helpers are started with the
  lock fd (9) and the terminal fds (3, 4) closed.

## 6. Names

**Strict mode** (`--user`, an `OMARCHY_USER` value, a `DEFAULT_USER` preseed, interactive
answers, renames). The name must match `^[a-z_][a-z0-9_-]{0,31}$` and be at most
**31** characters, because systemd and utmp reject 32-character user names. It must
not be a reserved name. Reserved names are the system accounts and groups of
Arch/ALARM, Debian/Ubuntu and common packages (`root`, `daemon`, `wheel`, `games`,
`users`, `docker`, `sshd`, `admin`, ...), every `systemd-*` name and every name
starting with `_`. Invalid names are rejected with a reason and a suggestion; they
are never rewritten silently.

**Collisions** (checked against the account database). The name must not belong to
another uid or to an existing group, with one exception: a group of that name with
gid 1000 is reused as the owner's primary group. If gid 1000 is taken by a
differently named group, the owner's group gets the next free gid and a warning is
printed.

**Suggest mode** (detected Windows names). Transliteration is locale-independent and
identical on glibc and macOS:

1. An explicit table maps Latin-1 Supplement, Latin Extended-A and some Extended-B
   letters, in both cases. It was generated from Unicode NFKD and checked against
   it, and adds the letters NFKD cannot decompose: `ß→ss`, `æ→ae`, `ø→o`, `ł→l`,
   `đ→d`, `þ→th`, `œ→oe`, `ı→i`, ...
2. Any remaining non-ASCII text goes through `python3 -I -S` NFKD with an ASCII
   filter (isolated mode, so a module planted in the working directory cannot load).
   Without python3, or with `OMARCHY_TRANSLIT=table`, it is dropped.
3. Lowercase ASCII. Every run of other characters becomes `_`; runs of `_`/`-` that
   contain an underscore collapse to `_`, and runs of `-` to `-`. Leading and
   trailing separators are stripped. A leading digit gets the prefix `u_`. The
   result is cut to 31 characters.
4. Nothing left means the deterministic fallback `omarchy`. A reserved or colliding
   suggestion becomes `u_<name>`, then `omarchy`, then `user1000`.

Examples (asserted exactly by the tests): `Müller→muller`, `François→francois`,
`José→jose`, `John Doe→john_doe`, `Straße→strasse`, `Ærøskøbing→aeroskobing`,
`jean-luc→jean-luc`, `123agent→u_123agent`, `Иван→omarchy`, `张伟→omarchy`,
`Nguyễn→nguyen` (`nguyn` without python3).

**Where the suggested name comes from** (create mode, no `--user`):
1. `DEFAULT_USER` in `/etc/omarchy-user.conf`, if valid and free (an image preseed).
2. Otherwise the Windows user name, the first of:
   * `omarchy.user=<name>` on the kernel command line (`.wslconfig` `kernelCommandLine`);
   * `$USERNAME` when `WSLENV` forwards `USERNAME`;
   * `cmd.exe /d /c "echo %USERNAME%"`, run with its working directory on the DrvFs
     drive that holds it, under `timeout 5`, stdin from `/dev/null`, CRs stripped.
     The literal `%USERNAME%` is rejected. **Skipped over SSH**, where the Windows
     identity may be a service account;
   * the single real profile under `<drive>/Users`. With more than one profile
     there is no guess.
3. Headless: the suggestion is used. Interactive: it is offered as the default, and
   up to 5 answers are validated strictly.

## 7. Creating the account (create mode)

* `/home/<name>` must not exist, unless it is a real directory owned by uid 1000
  (reused, with no skel copy and no history purge). A symlink, a file or another
  owner exits 3.
* Primary group: `groupadd -g 1000 <name>`, or an existing gid-1000 group of that
  name, or `groupadd <name>` when gid 1000 is taken (section 6).
* `useradd -m -u 1000 -g <name> -s /bin/bash -d /home/<name> [-k /etc/skel] <name>`.
* Adopt mode (an unprovisioned uid 1000, for example a stock image account) creates
  nothing. A missing home is created and seeded from `/etc/skel`.

## 8. Password and sudo

* **The OOBE never empties a password.** No password chosen means `passwd -l <owner>`
  (locked). Arch's PAM accepts empty passwords (`nullok`), so an empty one would be
  a login. A locked password still allows WSL logins, root's `su`/`runuser`, and
  SSH public-key logins when `UsePAM yes` **(unverified on Windows OpenSSH paths)**.
* A chosen password is set with `printf 'user:pw' | chpasswd`, on stdin only.
* Interactive runs, when a password was set and `--require-password` was not given,
  ask `Ask for this password when using sudo? [y/N]`.
* `/etc/sudoers.d/10-<owner>` contains **only** the owner rule: by default
  `<owner> ALL=(ALL:ALL) NOPASSWD: ALL`, or `<owner> ALL=(ALL:ALL) ALL` with
  `--require-password` (or after `y`). No `%wheel` rule is ever written. It is written
  to a temp file beside the target (named `.10-<owner>.omw.*`, which sudo's
  `@includedir` ignores), set to mode 0440 `root:root`, checked with `visudo -cqf`,
  then renamed into place. `/etc/sudoers.d` is created 0750 only when missing.
* If `/etc/sudoers` lacks an `@includedir`/`#includedir` line for the drop-in
  directory, the line is appended to a copy. The copy is validated with
  `visudo -cqf` and renamed over `/etc/sudoers`, and the live file is re-checked;
  any failure restores the original and exits 1.
* `--force` keeps the existing mode (`password` stays `password`) unless
  `--require-password` is given.

## 9. Linger, wsl.conf, home, environment, shims, state files

* **Linger:** an offline marker `/var/lib/systemd/linger/<owner>` (0644), plus
  `loginctl enable-linger` only when systemd is PID 1 (`/run/systemd/system` exists).
* **`/etc/wsl.conf`:** an awk INI edit writes `default = <owner>` in the first
  `[user]` section. It matches `[user]` case-insensitively (a trailing comment is
  allowed), drops duplicate `default` keys, appends the section when it is missing,
  creates the file when it is absent, preserves every other line including CRLF
  endings, and replaces the file atomically (mode 0644).
* **Home:** the home must be `/home/<name>`, not a symlink; otherwise scaffolding is
  skipped with a warning. Mode 0700. `~/.config`, `~/.local/{bin,share,state}` and
  the entries of `OMARCHY_HOME_DIRS` are created **as the owner** (`runuser`), so a
  re-run never follows a symlink planted in the home with root privileges.
  `OMARCHY_HOME_DIRS` accepts relative paths only: no absolute paths, every component
  starting with a letter, digit or `_` (so no `..`, `.` or hidden components), at
  most 32 entries. Rejected entries are reported. There are no
  hard-coded workspace directories. `~/.*_history`, `~/.lesshst` and `~/.viminfo` are
  purged **only from a home created by this run**, never on re-runs.
* **User environment:** `omarchy-nvim-setup`, `omarchy-theme-set "Tokyo Night"`
  (only while no theme is recorded; `OMARCHY_WSL_THEME_BRIDGE=0`), the btop theme
  link and `mise settings set upgrade.auto_prune false`. Each runs only if present,
  resolved to an absolute path, as the owner, with `env -i` (HOME, USER, LOGNAME,
  SHELL, PATH, TERM, LANG, `OMARCHY_PATH=/usr/share/omarchy`), bounded and non-fatal.
* **Windows tool shims:** `/usr/lib/omarchy-wsl/bin/wsl-shims-setup.sh` links
  PowerShell, cmd, wt and GCM into `/usr/lib/omarchy-wsl/bin`. It runs only if it is
  executable and binfmt `WSLInterop` or `WSLInterop-late` is registered **and
  enabled**. It runs with the OOBE's environment, so `WSL_INTEROP` of the launching
  Windows user reaches it, under `timeout 30`. A failure is a warning and never
  changes the exit status. In containers and image builds (no binfmt entry) it is
  skipped.
* **Sentinel** `/var/lib/omarchy/oobe_completed` (atomic, 0644, parsed never sourced):
  ```
  OOBE_VERSION=2.0.0
  PROVISIONED_UID=1000
  PROVISIONED_USER=<owner>
  WRITTEN_BY=oobe            # omarchy-rename-owner after a rename
  COMPLETED_AT=<UTC ISO-8601>
  ```
* **`/etc/omarchy-user.conf`** (atomic, 0644, parsed with a whitelist reader, never
  sourced). The OOBE sets `DEFAULT_USER=<owner>` and keeps every other line. When the
  file does not exist it is seeded from `/usr/share/omarchy-wsl/omarchy-user.conf.default`
  (the repository's `wsl/omarchy-user.conf`), so the documented keys are present.
  Keys read: `DEFAULT_USER` (preseed, strict) and `OMARCHY_HOME_DIRS`. Syntax is
  `KEY=VALUE`, `KEY="VALUE"` or `KEY='VALUE'`, full-line `#` comments, no expansion
  and no inline comments. The writer only accepts values made of letters, digits,
  spaces and `_ . / : @ , + = % -`; quotes, `$`, backquotes, backslashes and
  newlines are refused.

The OOBE no longer installs sysctl, cgroup or systemd slice files at runtime. The
package installs them at build time.

## 10. `wsl --import` fallback: `/etc/profile.d/00-omarchy-firstboot.sh`

POSIX `sh` only (sourced by bash, sh and zsh login shells). It is inert unless **all**
of these hold:
* the shell is root's, interactive (`$-` contains `i`), with stdin and stdout on a
  terminal;
* `/var/lib/omarchy/oobe_completed` does not exist;
* `SUDO_USER` is unset, and no ancestor process (checked through `/proc/<pid>/status`)
  has a non-root real uid. `sudo -i`, `su -` and `runuser` from another account keep
  the caller's real uid in their own process.

It runs `/usr/lib/wsl/oobe.sh` (or the compat path). On exit 0 it switches the session
with `exec runuser -u <uid-1000 name> -- bash -l`. On failure it says so and leaves the
root shell; the next root login tries again. Concurrent runs are serialized by the
OOBE's lock (exit 75).

## 11. Renaming the owner: `omarchy-rename-owner`

```
omarchy-rename-owner [-n|--dry-run] [-y|--yes] [--from NAME] [--no-compat-symlink]
                     [--json] [-q|--quiet] [-h|--help] [--version] <new-name>
```

* **Root only, from a root session.** Non-root exits 3 and prints the exact command,
  for example `wsl.exe -d <distro> -u root -- omarchy-rename-owner -y jane`.
  `--dry-run` also works without root.
* **Preconditions (exit 3):** the new name is strict-valid; it is not an existing user
  or group, not an existing `/home/<name>` (except the tool's own compatibility
  symlink pointing at the current home, so renaming back works), and not a tenant
  name (`/var/lib/omarchy/tenants/<name>`); `--from` matches the current owner; there
  is confirmation (`--yes`, or typing the new name on a terminal); and uid 1000 runs
  nothing except its systemd user manager. Other processes, such as shells, tmux or
  editors, are listed. The tool never kills them; close the sessions, then
  `wsl.exe --terminate <distro>` and re-run from a root session.
* **Ordered, journaled steps.** Before the first change, `passwd`, `shadow`, `group`,
  `gshadow`, `subuid`, `subgid`, the sudoers drop-in, `wsl.conf`, `omarchy-user.conf`
  and the sentinel are copied to `/var/lib/omarchy/backups/rename-owner-<ts>-<pid>/`,
  and `/var/lib/omarchy/rename-owner.journal` is opened. Each step first checks the
  current state, so a re-run resumes:
  1. `stop-user-manager`: `loginctl disable-linger <old>` and `systemctl stop user@1000.service`
     (only under systemd), then require no uid-1000 process;
  2. `rename-login`: `usermod -l <new> <old>`;
  3. `subids`: rename `<old>:` entries in `/etc/subuid` and `/etc/subgid` if usermod left them;
  4. `rename-group`: `groupmod -n <new> <old>` when the primary group is named `<old>`;
  5. `move-home`: `usermod -d /home/<new> -m <new>` when the home is `/home/<old>`;
  6. `git-repair`: `git worktree repair` for repositories under the new home that have
     linked worktrees (`find -xdev -maxdepth 5`, as the owner, `timeout 60`). It runs
     before the symlink exists, so git sees and fixes the old paths;
  7. `compat-symlink`: `ln -s /home/<new> /home/<old>` (skipped with `--no-compat-symlink`);
  8. `sudoers`: `10-<old>` becomes `10-<new>` with the same mode, via `configure_sudoers`
     (`visudo -cf`, owner-only). An unmanaged `10-<old>` is left alone and reported;
  9. `linger`: the marker moves, and `loginctl enable-linger <new>` runs under systemd;
  10. `wsl-conf`: `[user] default = <new>` when it named `<old>`;
  11. `sentinel`: the sentinel (`WRITTEN_BY=omarchy-rename-owner`) and `DEFAULT_USER`;
  12. `spool`: `/var/spool/{cron,mail}/<old>` becomes `<new>`;
  13. `verify`: owner name and uid, home, `visudo -c`, `wsl.conf`, sentinel.
* **Rollback.** On a failed step, a failed verification or SIGINT/SIGTERM/SIGHUP,
  completed steps are undone in reverse order. Each step is registered before it runs
  and every undo checks the current state, so a step interrupted mid-way is undone
  too. Undoing the home move also repairs worktrees back to the old paths and
  restores a removed compatibility symlink. The tool exits 1 when fully rolled back,
  4 when a rollback step failed (the journal is kept, and the backups and a
  `--from <old> <new>` re-run are suggested), and `128+n` for signals. Signals are
  ignored while a rollback runs.
* **Idempotent.** When uid 1000 already has the new name and the state agrees, the
  tool prints "nothing to do" and exits 0 without running anything. When the state
  still names the old account (a manual `usermod`), it exits 3 asking for
  `--from <old>`; with `--from <old>`, the remaining steps are completed.
* **Never:** `rm -r`, changing uid/gid numbers, touching Windows files or the registry.
  The Windows follow-ups are printed instead: `wsl.exe --terminate <distro>`, scripts
  using `wsl.exe -u <old>` or `--cd /home/<old>`, Windows Terminal profiles, Explorer
  Quick Access pins. `.wslconfig` needs no change.
* `--dry-run` validates and prints the 13-step plan without creating anything: no
  lock, no journal, no backup directory. `--json` prints one JSON document
  (`steps`, `result`: planned, renamed, nothing-to-do, rolled-back or
  rollback-incomplete).
* Exit 75 when the account lock is held.

## 12. Files

| Repository | Installed as | Mode |
|---|---|---|
| `wsl/oobe.sh` | `/usr/lib/wsl/oobe.sh` (+ symlink `/usr/lib/omarchy-wsl/oobe.sh`) | 0755 |
| `lib/omarchy-wsl-account.sh` | `/usr/lib/omarchy-wsl/account.sh` | 0644 |
| `lib/omarchy-wsl-common.sh` | `/usr/lib/omarchy-wsl/common.sh` | 0644 |
| `bin/omarchy-rename-owner` | `/usr/bin/omarchy-rename-owner` | 0755 |
| `wsl/profile.d/00-omarchy-firstboot.sh` | `/etc/profile.d/00-omarchy-firstboot.sh` | 0644 |
| `wsl/omarchy-user.conf` | `/usr/share/omarchy-wsl/omarchy-user.conf.default` | 0644 |

**Account library API** (`account.sh`, bash 3.2 compatible, sourced by the OOBE,
`omarchy-rename-owner` and the tests): `sanitize_username`, `suggest_username`,
`validate_username`, `omw_name_conflict`, `owner_name`, `owner_home`, `omw_getent`,
`configure_sudoers`, `sudoers_mode_of`, `remove_sudoers` (only files carrying the
managed marker), `configure_linger`, `remove_linger`, `update_wsl_conf_default_user`,
`wsl_conf_default_user`, `write_sentinel`, `sentinel_get`, `sentinel_provisioned`,
`write_user_conf`, `user_conf_default_user`, `user_conf_home_dirs`, `omw_acct_lock`.
**Common library** (`common.sh`): logging to stderr, coloured only when stderr is a
terminal and `NO_COLOR` is unset (and `TERM` is not `dumb`), with `tskey-…` masked;
the whitelist key=value reader and writer; atomic writes; temp-file cleanup; `flock`
helpers.

## 13. Verification

| Suite | Command | What it runs |
|---|---|---|
| OOBE (bash) | `bash tests/test_oobe_adversarial.sh` | T1: the real `oobe.sh` and library against a sandbox (fake passwd/group/shadow, recorder stubs for useradd/usermod/passwd/chpasswd/runuser/loginctl/cmd.exe/helpers, the real `visudo`), including prompts through fd 3/4 and one real pty (`script`), signals, the lock, timeouts, shims and the profile hook. T2 (root in a throwaway container): the exact CI command with real `useradd`, `visudo -c`, `sudo -n`, `su`, plus the profile hook through a real pty. |
| Rename (bash) | `bash tests/test_rename_owner.sh` | T1: plan order, `--dry-run` byte-identical sandbox, the name table, exact state restoration after a fault at every step, an incomplete rollback (exit 4) then a resumed run, SIGTERM/SIGINT rollback, sessions, the lock, JSON. T2: real `usermod`/`groupmod`/`git worktree`, `sudo`, `su -`, rollback and SIGTERM with real tools. |
| Library (pytest) | `python3 -m pytest -q tests/unit/test_oobe_adversarial.py` | Exact transliteration in both modes and three locales, validation, INI edits, the key=value reader (no execution), sentinel and user.conf, CLI exit codes, the profile hook. Identical results on Linux and macOS. |

Each bash suite ends with `<Suite>: P/R passed, F failed, S skipped`. `OMW_STRICT=1`
turns any skip into a failing exit status and makes a missing T2 tier (not root in
a container) a failure. `OMW_REAL_ROOT=0` disables T2 explicitly.

**Not verified by any test:** the T2 tiers run on the Ubuntu-based test image, not
on the Arch rootfs (Arch's `useradd`/`usermod`/PAM defaults are not exercised); a
real WSL first launch (Store or `.wsl` package),
Windows interop answers from a real `cmd.exe`, `loginctl enable-linger` against a
live logind (it is stubbed), and the real `wsl-shims-setup.sh` (it is stubbed in
these suites).

## 14. Test seams

Environment variables, defaulting to the real paths: `OMARCHY_SENTINEL_DIR`,
`OMARCHY_USER_CONF`, `OMARCHY_USER_CONF_TEMPLATE`, `OMARCHY_WSL_CONF`,
`OMARCHY_SUDOERS_DIR`, `OMARCHY_SUDOERS_MAIN`, `OMARCHY_LINGER_DIR`,
`OMARCHY_PASSWD_ROOT` (read `<dir>/etc/{passwd,group}` instead of NSS),
`OMARCHY_HOME_ROOT`, `OMARCHY_SKEL_DIR`, `OMARCHY_LOCK_FILE`, `OMARCHY_TENANT_ROOT`,
`OMARCHY_TRANSLIT=auto|table`, `OMARCHY_NOW`, `OMARCHY_SYSTEMD_RUNNING=0|1`,
`OMARCHY_NO_TTY`, `OMARCHY_TTY_IN`/`OMARCHY_TTY_OUT`, `OMARCHY_PACMAN_INIT`,
`OMARCHY_DRVFS_ROOTS`, `OMARCHY_PROC_CMDLINE`, `OMARCHY_SYNC_TIMEOUT`,
`OMARCHY_SHIMS_SETUP`, `OMARCHY_SHIMS_TIMEOUT`, `OMARCHY_BINFMT_DIR`,
`OMARCHY_ALLOW_NONROOT=1` (sandboxed tests only), `OMARCHY_WSL_LIB_DIR`.
Rename only: `OMARCHY_PROC_ROOT`, `OMARCHY_SPOOL_DIR`, `OMARCHY_FAULT_AT=<step>`,
`OMARCHY_FAULT_UNDO=<step>`, `OMARCHY_PAUSE_AT=<step>` (+ `OMARCHY_PAUSE_FILE`).

## 15. Changes from 1.0.0

* Identity is keyed on uid 1000. A re-run no longer renames the owner back to a
  stale name in the config file, no longer runs `pkill -u 1000`, and a different
  `--user` is refused instead of renaming the owner.
* Sudoers: owner rule only, with no `%wheel NOPASSWD`. The `@includedir` append is
  validated and rolled back on failure. `--require-password` is honoured.
* Passwords are locked instead of emptied (`passwd -d` removed). Prompts go through
  `/dev/tty`; the password choice was previously captured by `$(...)` and lost.
* The `iconv //TRANSLIT` transliteration (locale-dependent; `Müller` became `m_uller`
  on macOS) is replaced by the explicit table plus NFKD.
* Separate signal traps (an interrupted OOBE previously exited 0), `flock`, bounded
  helpers, and network syncs run only with `--sync-network`.
* Removed: the runtime copy of sysctl/cgroup/slice files, the hard-coded home
  workspace directories, and the history purge on re-runs.
* Added: adopt mode for an unprovisioned uid 1000, group-collision handling, user.conf
  seeding from the template, Windows shims at first launch, and `omarchy-rename-owner`.
