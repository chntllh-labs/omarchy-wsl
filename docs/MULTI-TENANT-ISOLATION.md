# Omarchy-WSL: Multi-Tenant Isolation (`omarchy-tenant`)

`omarchy-tenant` runs isolated guests ("tenants") inside one Omarchy WSL
distro, for people who should get a Linux shell but must not get the
Windows owner's trust. This document describes the threat model, what the
tool generates, how it checks itself, and what has and has not been verified.

- Tool: `bin/omarchy-tenant`, installed as `/usr/bin/omarchy-tenant` (0755)
- In-tenant templates: `wsl/tenant/*`, installed to `/usr/share/omarchy-wsl/tenant/` (0644)
- Shared library: `lib/omarchy-wsl-common.sh`, installed as `/usr/lib/omarchy-wsl/common.sh`
- Tests: `tests/test_tenant.sh` (T1 stub tier), goldens in `tests/fixtures/tenant/`

## 1. Why a second Linux user is not a boundary

WSL's Windows integration is configured per distro, not per Linux user:

| WSL feature | Who gets it inside the distro |
|---|---|
| Interop (`[interop] enabled`) | Every Linux process can run `powershell.exe`/`cmd.exe`, which run **as the Windows user who started WSL**. There is no per-user or per-group switch. |
| DrvFs automounts (`/mnt/c`, ...) | Every Linux user, within the automount permissions in `/etc/wsl.conf`; with permissive masks other users can read the Windows profile, and interop gives write access as the owner anyway. |
| `/mnt/wsl`, `/usr/lib/wsl`, `/run/WSL`, `/dev/dxg` | Shared by every process in the VM. |
| `AF_VSOCK` | Any process can open hvsock connections to services the Windows host exposes to the VM. |

A second account in `/etc/passwd` therefore still reaches the owner's Windows
files and can act as the owner on Windows. `omarchy-tenant` is the boundary:
a tenant is a container that has none of the above.

## 2. Threat model

**Assets:** the Windows owner's files, credentials and processes; the WSL
host's own services (loopback listeners, the Docker socket, the owner's
tailnet); the LAN behind the Windows host; other tenants.

**Adversary:** a person with an SSH login to a tenant who can run arbitrary
code as the tenant user (and, inside the tenant, as the tenant's root).

What a tenant **can** reach:

| Resource | How |
|---|---|
| The public internet (IPv4) | slirp4netns user-mode NAT; its host-side sockets are filtered by the unit's `IPAddressDeny=` |
| Its own tailnet | `tailscaled --tun=userspace-networking` inside the tenant, logged in with `omarchy-tenant auth-url` |
| Public DNS resolvers | `/etc/resolv.conf` inside the tenant (default `1.1.1.1`, `9.9.9.9`; `--dns` to choose) |
| Its own disk image, CPU and memory share | sparse `disk.raw`, `MemoryMax=`, `CPUQuota=`, `TasksMax=` |

What a tenant **cannot** reach (each item is enforced by the generated files
and checked by the isolation self-check, section 6):

| Denied | Enforced by |
|---|---|
| Host loopback services (`127.0.0.0/8`, `::1`, `0.0.0.0/8`) | `slirp4netns --disable-host-loopback` and `IPAddressDeny=` |
| WSL NAT gateway, Windows host DNS proxy, the LAN (RFC 1918) | `IPAddressDeny=` |
| CGNAT / tailnet addresses of the host (`100.64.0.0/10`) | `IPAddressDeny=`; the tenant's own tailnet is reached only through its userspace `tailscaled` |
| Link-local and cloud metadata (`169.254.0.0/16`, `fe80::/10`) | `IPAddressDeny=` |
| ULA IPv6, multicast, reserved ranges | `IPAddressDeny=` |
| hvsock to the Windows host | `RestrictAddressFamilies=~AF_VSOCK` (seccomp, inherited by the container) |
| io_uring | `SystemCallFilter=~io_uring_setup io_uring_enter io_uring_register` in the unit and the `.nspawn` |
| `/mnt/*`, `/mnt/wsl`, `/usr/lib/wsl`, `/run/WSL`, `/dev/dxg`, `/init` | The tenant boots from its own image; the `.nspawn` has no `Bind=`/`Overlay=` (the self-check rejects them) |
| Windows interop | Same as above: no WSL binfmt handler, no interop socket, no DrvFs inside the container |
| Host UIDs | `PrivateUsers=pick`: tenant root is an unprivileged UID range on the host |
| The host journal | `LinkJournal=no` |
| Gaining privileges via setuid binaries | `NoNewPrivileges=yes` |
| Host DNS configuration | `ResolvConf=off`; the tenant gets its own `resolv.conf` |

**Out of scope:** kernel vulnerabilities (all tenants share the WSL kernel),
CPU side channels, a compromised Windows host or WSL VM, disk I/O fairness
beyond `IOWeight=`, and the privacy of DNS queries (section 9).

## 3. Architecture

```
 Windows host ──hvsock── WSL VM kernel
                           │
   distro (systemd PID 1) ─┤ owner uid 1000, interop, /mnt/c ...
                           │
   omarchy-tenant-<name>.service  (machine.slice, IPAddressDeny=, ~AF_VSOCK, ~io_uring)
     ├─ systemd-nspawn --image=<root>/<name>/disk.raw  (PrivateUsers=pick, Private=yes)
     │    └─ tenant: systemd, sshd on 127.0.0.1:22, tailscaled --tun=userspace-networking
     └─ ExecStartPost: omarchy-tenant _net-up <name>
          └─ slirp4netns --disable-host-loopback --disable-dns <leader> tap0
               (runs in the unit's cgroup, so IPAddressDeny= filters its sockets)
```

The container has its own network namespace with `lo` only. `_net-up` waits
for the container leader, then starts `slirp4netns`, which creates `tap0`
inside the container (10.0.2.100/24, gateway 10.0.2.2) and turns the tenant's
traffic into ordinary sockets on the host. Those sockets belong to the unit's
cgroup, so the cgroup-BPF `IPAddressDeny=` applies to them.

## 4. Commands

```
omarchy-tenant [global options] <command> [args]

create <name> [--size 20G] [--mem 4G] [--cpus 2] [--tasks 512]
              [--bootstrap | --image TAR] [--key FILE | --key-stdin]
              [--dns IP[,IP,IP]] [--allow-overcommit] [--no-start]
              [--harden-host-io-uring]
key <name> add FILE|-   |   key <name> list [--json]   |   key <name> remove SHA256:FPR
auth-url <name> [--timeout 60] [--authkey-file FILE | --authkey-stdin]
status [<name>] [--json]
list [--json]
start <name> | stop <name>
destroy <name> [--keep-data] [--yes]
doctor [--tenant NAME]

Global (also accepted after the command): -n/--dry-run, -y/--yes, --json,
-q/--quiet, --root DIR (default /var/lib/omarchy/tenants), -h/--help, --version
```

Typical session (as root; from Windows use `wsl.exe -d Omarchy -u root -- omarchy-tenant ...`):

```bash
omarchy-tenant create jane --mem 2G --cpus 1 --key /tmp/jane.pub   # build, start, self-check
omarchy-tenant auth-url jane          # prints https://login.tailscale.com/a/...
omarchy-tenant status jane            # running, tailnet IPs, isolation: ok
omarchy-tenant key jane add /tmp/jane-laptop.pub
omarchy-tenant destroy jane --yes
```

**Names** match `^[a-z][a-z0-9-]{0,30}$`, must not end with `-`, must not be
reserved (`root host localhost omarchy machines all list default none self
tenant tenants`) and must not collide with a user or group on the host. The
tenant name is also the machine name, the hostname and the login user inside
the tenant.

**Sizes** are `<n>M` or `<n>G` (binary units, like systemd); `--size` is at
least 1G, `--mem` at least 128M; `--cpus` 1..256 (becomes `CPUQuota=<n*100>%`);
`--tasks` 16..65536.

**Mutating commands need root** (exit 3 with the `sudo` and `wsl.exe -u root`
commands to use) except with `--dry-run`, which renders every file and prints
every command but creates nothing: no directory, no lock file, no mount.

### create

1. Validate options, key input and the name; refuse a `--root` that is a system
   directory, a Windows/WSL-managed path, or on a 9p/DrvFs/virtiofs/network
   filesystem.
2. Disk preflight: refuse (exit 3) unless the free space on the state
   filesystem covers the new sparse cap plus what existing tenants can still
   grow into: `new cap + Σ(cap_i − allocated_i) <= free`. `--allow-overcommit`
   turns this into a warning.
3. Take the per-tenant lock (`<root>/.locks/<name>.lock`, `flock -n`; exit 75
   when busy), create `<root>/<name>/` (0700) and `tenant.conf` (state
   `creating`).
4. Journaled steps (`<root>/<name>/journal`; a re-run resumes after the last
   finished step):
   `keys` (host `authorized_keys`, 0600) → `disk` (`truncate -s`,
   `mkfs.ext4 -q -F`) → `rootfs` (loop-mount `nosuid,nodev` under
   `/run/omarchy-tenant/<name>/mnt`; `pacstrap -c -K <mnt> base openssh
   tailscale` or `tar --numeric-owner -xpf TAR`; write the in-tenant files;
   `systemctl --root=<mnt> enable sshd.service tailscaled.service`; unmount)
   → `units` (unit + `.nspawn`, `daemon-reload`, `enable`) → `ready`.
5. Unless `--no-start`: start the unit and run the isolation self-check. A
   failing check stops **and disables** the tenant and exits 4.

Re-running `create` for a ready tenant whose rendered files are unchanged
executes no command at all ("already exists"). If the unit or `.nspawn`
differ from what this version renders (edited, or a newer tool version), they
are re-rendered and systemd is reloaded; the disk is never touched. Explicit
settings that differ from the stored ones (`--mem 8G` for a 4G tenant) are
refused (exit 3): destroy and create again to change them. New keys go
through `key add`.

In-tenant files written into the image (templates in
`/usr/share/omarchy-wsl/tenant/`, `@TENANT@` replaced by the name):

| File in the tenant | Purpose |
|---|---|
| `/etc/ssh/sshd_config` | key-only, `ListenAddress 127.0.0.1`/`::1`, `AuthorizedKeysFile /etc/omarchy-tenant/authorized_keys`, `AllowUsers <name>`, no forwarding/X11/tunnels, `PermitRootLogin no` |
| `/etc/systemd/system/tailscaled.service.d/10-omarchy-tenant.conf` | `tailscaled --tun=userspace-networking --port=0` |
| `/etc/sysusers.d/omarchy-tenant.conf`, `/etc/tmpfiles.d/omarchy-tenant.conf` | the login user and its 0700 home, created by the tenant's systemd on first boot |
| `/etc/hostname`, `/etc/resolv.conf` | name; the chosen public resolvers |
| `/etc/omarchy-tenant/authorized_keys` | copy of the host-side key list |

Writes into the image refuse to follow a symlinked parent directory and replace
(never follow) a symlinked target, so an `--image` tarball cannot redirect
them onto the host. `--image` must still be a rootfs you trust: it is
extracted as root (GNU tar strips leading `/` and skips members containing `..`, but the content itself is trusted).

### key

Public keys only. The input (file or `-` for stdin, at most 64 KiB) is
rejected as a whole (exit 2, nothing stored, the material is never echoed)
if it contains private key material (`PRIVATE KEY`, PuTTY or SSH2 private
files), if a line does not start with an allowed key type (`ssh-ed25519`,
`sk-ssh-ed25519@openssh.com`, `ecdsa-sha2-nistp256/384/521`,
`sk-ecdsa-sha2-nistp256@openssh.com`, `ssh-rsa`) — so `from=`/`command=`
option prefixes are refused — if `ssh-keygen -l` rejects a key, or if an RSA
key has fewer than 3072 bits. Keys are de-duplicated by SHA256 fingerprint and
stored normalized (`type base64 comment`) in `<root>/<name>/authorized_keys`
(0600, the source of truth). The list then reaches the tenant through `stdin`
of `systemd-run --machine=<name> --pipe` when it runs, or by loop-mounting its
stopped image (ownership copied from the image's `/etc`); detached and
half-created tenants are synced when they are re-attached or resumed.
`remove` with an unknown fingerprint exits 5.

### auth-url (tailnet login)

Auth keys never travel on the command line: any argument containing `tskey-`
is refused (exit 2) and every `tskey-...` in output is masked as `tskey-****`.

- Without a key: start `tailscale up --ssh=false --accept-dns=false
  --accept-routes=false --hostname=<name>` inside the tenant in the
  background, poll `tailscale status --json` for `AuthURL` (must be
  `https://...`) and print it on stdout. Already logged in: exit 0, no URL.
  No URL within `--timeout` seconds: exit 1.
- With `--authkey-file FILE` or `--authkey-stdin`: the key (must match
  `^tskey-[A-Za-z0-9_-]+$`) is written into the tenant at
  `/run/omarchy-tenant/ts-authkey` (mode 0600) through stdin, `tailscale up
  ... --auth-key=file:/run/omarchy-tenant/ts-authkey` runs, and the file is
  removed afterwards (also on failure).

The tool never passes `--advertise-routes`, `--advertise-exit-node` or
`--exit-node`, and never runs the host's `tailscale`.

### destroy

Requires `--yes` (or typing the name at a terminal; without a terminal, exit 3).
The tenant directory must be a real directory exactly at
`realpath(<root>)/<name>`; a symlink or anything resolving elsewhere is
refused (exit 3). The unit is stopped and disabled, the unit and `.nspawn`
are removed, systemd is reloaded, then the known files (`tenant.conf`,
`disk.raw`, `authorized_keys`, `journal`) are deleted one by one and the
directory is removed with `rmdir`. Unknown files are left in place with a
warning. Nothing is ever deleted with `rm -rf`. `--keep-data` keeps the
directory and marks the tenant `detached`; `create <name>` re-attaches it
(units only, no disk rebuild).

### doctor

Reports, never changes: systemd as PID 1, the host commands, cgroup v2, user
namespaces, `/dev/net/tun`, `/dev/loop-control`, the filesystem of the state
root, and `kernel.io_uring_disabled`. Exit 3 if a prerequisite fails. With
`--tenant NAME` it also runs the isolation self-check (exit 4 on failure).

## 5. Generated files

`<root>` defaults to `/var/lib/omarchy/tenants` (0700).

| Path | Mode | Content |
|---|---|---|
| `<root>/<name>/tenant.conf` | 0600 | `version name state size mem cpus tasks dns image_source created_at`; `key=value`, parsed by a whitelist reader with per-key validation, never sourced |
| `<root>/<name>/disk.raw` | | sparse ext4 image (the tenant's root) |
| `<root>/<name>/authorized_keys` | 0600 | host-side key list |
| `<root>/<name>/journal` | | finished creation steps |
| `<root>/.locks/<name>.lock` | | per-tenant `flock` |
| `/etc/systemd/system/omarchy-tenant-<name>.service` | 0644 | the unit (below) |
| `/etc/systemd/nspawn/<name>.nspawn` | 0644 | container settings (below) |
| `/run/omarchy-tenant/<name>/` | 0700 | mount point while building, `slirp4netns.pid` |
| `/etc/sysctl.d/60-omarchy-tenant-io-uring.conf` | 0644 | only with `create --harden-host-io-uring` |

The rendered unit (golden: `tests/fixtures/tenant/omarchy-tenant-alice.service.golden`),
modelled on `systemd-nspawn@.service`:

```ini
[Service]
Type=notify
ExecStart=/usr/bin/systemd-nspawn --quiet --keep-unit --register=yes --boot --link-journal=no --settings=override --machine=<name> --image=<root>/<name>/disk.raw
ExecStartPost=/usr/bin/omarchy-tenant _net-up <name>
KillMode=mixed
Slice=machine.slice
Delegate=yes
DelegateSubgroup=supervisor
TasksMax=512
MemoryMax=4G
MemorySwapMax=0
CPUQuota=200%
IOWeight=50
DevicePolicy=closed
DeviceAllow=/dev/net/tun rwm        # plus char-pts, loop-control, block-loop, block-blkext
IPAddressDeny=0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4 ::1/128 fc00::/7 fe80::/10 ff00::/8
RestrictAddressFamilies=~AF_VSOCK
SystemCallFilter=~io_uring_setup io_uring_enter io_uring_register
SystemCallErrorNumber=EPERM
```

The `.nspawn` (golden: `tests/fixtures/tenant/alice.nspawn.golden`):

```ini
[Exec]
Boot=yes
PrivateUsers=pick
NoNewPrivileges=yes
Hostname=<name>
ResolvConf=off
Timezone=off
LinkJournal=no
DropCapability=CAP_NET_RAW CAP_MKNOD CAP_SYS_PTRACE
SystemCallFilter=~io_uring_setup io_uring_enter io_uring_register

[Files]
PrivateUsersOwnership=auto

[Network]
Private=yes
VirtualEthernet=no
```

`NoNewPrivileges=yes` means `sudo`/`su` do not work inside a tenant; the
tenant user is not meant to administer it. Administration happens from the
host with `omarchy-tenant`.

## 6. Isolation self-check

Runs after `create` and every `omarchy-tenant start`, and for
`doctor --tenant NAME`. Any failure of the first two groups is fatal
(exit 4; after `create`/`start` the tenant is stopped and disabled).

1. **Policy (static):** the unit and `.nspawn` on disk contain every required
   line verbatim (`ExecStart=`, `ExecStartPost=`, `KillMode=mixed`,
   `Delegate=yes`, `MemorySwapMax=0`, `DevicePolicy=closed`, the full
   `IPAddressDeny=` list, `RestrictAddressFamilies=~AF_VSOCK`, both io_uring
   filters, `SystemCallErrorNumber=EPERM`, `PrivateUsers=pick`,
   `NoNewPrivileges=yes`, `ResolvConf=off`, `LinkJournal=no`, `Private=yes`,
   `VirtualEthernet=no`) and the `.nspawn` has no `Bind=`, `BindReadOnly=`,
   `BindUser=`, `Overlay=`, `OverlayReadOnly=`, `Interface=`, `MACVLAN=`,
   `IPVLAN=`, `Bridge=`, `Zone=`, `Port=` or `VirtualEthernetExtra=`.
2. **Live (running tenants):** the container leader (`machinectl show -p
   Leader`) has a non-identity `uid_map`, `Seccomp: 2`, `NoNewPrivs: 1` and a
   network namespace different from the host's. A POSIX probe run inside
   with `systemd-run --machine=<name> --wait --pipe` must find none of
   `/mnt/c`, `/mnt/wsl`, `/usr/lib/wsl`, `/run/WSL`, `/dev/dxg`, `/init`, and
   must fail to open TCP connections (3 s timeout each) to `10.0.2.2:22`,
   `10.0.2.2:80`, `169.254.169.254:80`, every IPv4 nameserver of the WSL host
   on port 53 and the host's default gateway on port 53. The last two usually
   have real listeners (WSL's DNS proxy), so a refused connection there
   demonstrates the filter rather than an idle port. A probe that cannot run, or a container that does
   not become reachable within the wait bound, counts as a failure.
3. **Drift (reported, not fatal):** the files differ from what this version
   would render (for example a hand-edited comment or limit). `status` shows
   `"policy": "drift"`.

`status` runs only the static check (it is cheap); use `doctor --tenant NAME`
for the live checks.

## 7. Exit codes

| Code | Meaning |
|---|---|
| 0 | success (including "already exists" and "nothing to do") |
| 1 | failure (a command failed, corrupt state, no login URL in time) |
| 2 | usage: unknown option or command, invalid value, auth key on argv, invalid key input |
| 3 | precondition: not root, missing host commands, invalid or colliding name, not enough disk, unsafe `--root` or tenant path, destroy without `--yes`, tenant not running or not ready |
| 4 | isolation self-check failed (tenant stopped and disabled when it was just started) |
| 5 | tenant or key fingerprint not found |
| 75 | busy: another `omarchy-tenant` holds the tenant's lock |
| 128+n | interrupted by signal n (INT 130, TERM 143, HUP 129); finished steps are journaled and a re-run resumes |

## 8. `status --json` schema

```json
{
  "version": 1,
  "tenants": [
    {
      "name": "alice",
      "state": "running",
      "size": "20G",
      "mem": "4G",
      "cpus": 2,
      "tasks": 512,
      "disk_allocated_bytes": 1342177280,
      "keys": 2,
      "tailnet": { "backend_state": "Running", "ips": ["100.101.102.103"] },
      "isolation": { "policy": "ok", "missing": [] }
    }
  ]
}
```

- `state`: `running | stopped | failed` for created tenants (from
  `systemctl is-active`), otherwise `creating | detached`.
- `tailnet.backend_state` is `null` and `ips` empty unless the tenant runs.
- `isolation.policy` is `ok` or `drift`; `missing` lists missing policy lines
  (`unit:<line>`, `nspawn:<line>`), forbidden settings
  (`nspawn:forbidden:<line>`) and `unit:content-differs` /
  `nspawn:content-differs`.

`list --json` prints `{"version":1,"tenants":[{"name":...,"state":...}]}`.
`key <name> list --json` prints
`{"version":1,"tenant":...,"keys":[{"fingerprint":...,"type":...,"bits":...,"comment":...}]}`.

## 9. DNS and io_uring caveats

**DNS.** `slirp4netns --disable-dns` removes slirp's built-in resolver (which
forwards to the host's, that is to Windows and the owner's network). The
tenant therefore asks public resolvers directly (`1.1.1.1` and `9.9.9.9`
unless `--dns` names up to three other public IPv4 resolvers), and their
operators see the tenant's queries. Private or link-local resolvers are
refused at `create` because `IPAddressDeny=` would block them anyway.

**io_uring.** Tenants are always denied io_uring by seccomp. The global sysctl
`kernel.io_uring_disabled` affects every process in the WSL VM, including the
owner's tools, so the tool never sets it silently: `doctor` reports it, and
only `create --harden-host-io-uring` writes
`/etc/sysctl.d/60-omarchy-tenant-io-uring.conf` (`kernel.io_uring_disabled = 2`)
and applies it with `sysctl -p`. Delete the file and run `wsl --shutdown` to
undo.

The tool never writes `.wslconfig`, `/etc/wsl.conf` or the Windows registry.

## 10. Packages

Host (the Omarchy image): `systemd` (provides `systemd-nspawn`, `machinectl`,
`systemd-run` on Arch), `slirp4netns`, `e2fsprogs` (`mkfs.ext4`),
`util-linux` (`mount`, `mountpoint`, `flock`, `setsid`, `findmnt`), `openssh`
(`ssh-keygen`), `coreutils`; `arch-install-scripts` (`pacstrap`) for the
default `--bootstrap`, `tar` for `--image`.

Inside each tenant (installed by `pacstrap`, or required in the `--image`
tarball): `base`, `openssh`, `tailscale`.

## 11. Verification status

**T1, stub tier (done): `tests/test_tenant.sh`.** Runs as root or not, no
systemd needed. All state-changing host commands are argv recorders on PATH;
`ssh-keygen`, `flock` and `getent` are real; a fake `/proc` plays the
container leader. It locks the rendered unit, `.nspawn` and `tenant.conf` to
golden files, runs `systemd-analyze verify` on the unit, and covers: the CLI
and exit-code table; the root check; name and path-traversal rejection;
`--dry-run` leaving the state tree sha256-identical; the order of the
creation commands; idempotent create (no command on the second run);
re-render on drift; the overcommit arithmetic; the busy lock; missing host
commands; `--image`; symlinked `/etc` in an image; every self-check failure
mode; key validation, de-duplication, push and offline sync; auth keys never
in argv, stdout or stderr; `status --json`; destroy safety (`--yes`,
symlinked directories, unknown files, `--keep-data` and re-attach);
`_net-up`; `doctor`; the io_uring opt-in; SIGTERM (exit 143, unmount,
resume). Run with `OMW_STRICT=1` so skipped checks fail.

**T2, privileged systemd container (not done; future work).** Boot a real
tenant (`podman run --privileged --systemd=always`, x86_64 and arm64) and
assert each gate, failing (never skipping) under `OMW_STRICT=1`:

- `systemd-analyze verify` with the real binaries; the unit starts, `machinectl
  list` shows the tenant, `slirp4netns` is in the unit's cgroup and dies on stop.
- From inside: `socket(AF_VSOCK)` fails with `EAFNOSUPPORT`; `io_uring_setup`
  fails with `EPERM`; connections to `10.0.2.2`, the host loopback, the WSL
  gateway and DNS proxy, `169.254.169.254`, `100.64.0.0/10` and the RFC 1918
  ranges fail; a public `IP:443` succeeds.
- `/mnt/c`, `/mnt/wsl`, `/usr/lib/wsl`, `/run/WSL`, `/dev/dxg`, `/init` are absent.
- Tenant root maps to an unprivileged host UID range; `NoNewPrivs: 1`.
- sshd accepts the managed key, refuses passwords, root and forwarding;
  inbound tailnet TCP reaches sshd on the tenant's loopback with the pinned
  tailscale version.
- `PrivateUsersOwnership=auto` gives correct ownership for files written into
  a stopped image (`key add` offline sync).
- `MemoryMax=`/`TasksMax=` are enforced; `destroy` leaves nothing behind.

**T3, manual on real WSL (not done).** x64 and ARM64 hosts, NAT and mirrored
networking, `vmIdleTimeout`/`instanceIdleTimeout=-1`, tenant survives
`wsl --shutdown` and a Windows reboot, the WSL DNS proxy and gateway are
unreachable from the tenant, interop is absent, the owner's tools still work
with and without `--harden-host-io-uring`.

## 12. Limitations

- No live tier yet (T2/T3): the isolation claims above are enforced by the
  generated configuration and checked by the self-check, but have not been
  observed on a real WSL kernel by these tests.
- IPv6 egress is not provided (slirp4netns runs without `--enable-ipv6`).
- `status` only runs the static policy check.
- Tenants started by systemd at boot are not self-checked until the next
  `omarchy-tenant start` or `doctor --tenant`.
- The offline key sync mounts a stopped tenant's image; do not start the
  tenant with `systemctl` directly while `key add/remove` runs (the tool's own
  commands take the tenant lock).
- All tenants share the WSL kernel; kernel bugs are out of scope.
