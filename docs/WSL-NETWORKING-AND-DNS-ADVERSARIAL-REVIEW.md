# Adversarial Review: WSL Networking & DNS Topologies in Omarchy-WSL

**Distribution Engine:** Omarchy-WSL (Arch Linux for WSL2 / WSL 3.0.1)  
**Target Architectures:** ARM64 (`aarch64` / Qualcomm Snapdragon X Elite Oryon) and x86_64 (`amd64` / Intel/AMD)  
**Security & Reliability Target:** Zero-configuration resilience across NAT, Mirrored Networking, Corporate VPNs (GlobalProtect, AnyConnect, Zscaler), SSL-inspecting proxies, and enterprise firewalls.

---

## 1. Threat Model & Topological Realities

Running a bleeding-edge Arch Linux distribution inside Windows Subsystem for Linux (WSL) creates an operating system boundary fundamentally different from bare metal or conventional KVM/QEMU hypervisors:

```
+-------------------------------------------------------------------------+
|                              WINDOWS HOST                               |
|  +-------------------------------------------------------------------+  |
|  | Enterprise VPN Client (GlobalProtect / AnyConnect / Zscaler)      |  |
|  | Windows Defender Firewall & Hyper-V Virtual Firewall               |  |
|  | WinINet Proxy Settings (PAC URL / Corporate HTTP Proxy)           |  |
|  | Windows Root CA Store (Corporate Enterprise PKI / MITM Certs)     |  |
|  | Windows Host Services (svchost, IIS, BranchCache, Port 53/80/443)  |  |
|  +-------------------------------------------------------------------+  |
|                                    ^                                    |
|                 Hyper-V VFP / Hyper-V Switch / vsock                     |
|                                    v                                    |
|  +-------------------------------------------------------------------+  |
|  |                         OMARCHY-WSL GUEST                         |  |
|  |  systemd-resolved <---> glibc getaddrinfo / NSS                   |  |
|  |  pacman / curl / yay <---> corporate proxy & mirrorlist           |  |
|  |  dockerd / podman (pasta/netavark) <---> container bridges        |  |
|  |  aqua user (UID 1000) <---> unprivileged port binding & services  |  |
|  +-------------------------------------------------------------------+  |
+-------------------------------------------------------------------------+
```

In enterprise developer setups, the guest network is subjected to hostile network conditions:
1. **VPN Routing Hijacks:** Corporate VPNs claim default routes (`0.0.0.0/0`) and drop non-host source IP subnets (anti-spoofing).
2. **DNS Interception & Split Horizons:** Internal domain names resolve only via enterprise resolvers; public DNS (1.1.1.1, 8.8.8.8) is blocked by corporate border firewalls; DNSSEC records are stripped or invalid.
3. **SSL/TLS MITM Inspection:** Corporate proxies terminate TLS using custom enterprise root certificates not present in upstream Arch Linux `ca-certificates`.
4. **ICMP Blackholing:** Enterprise networks drop ICMP `ping` packets entirely, rendering legacy mirror-ranking tools (`reflector`) catastrophic failure vectors.
5. **Port & Subnet Collisions:** Host daemons clash with guest services, and container bridge subnets collide with corporate IP ranges.

Below is the adversarial analysis and mitigation strategy for every topological attack angle.

---

## 2. Attack Angle 1: `networkingMode=mirrored` vs `NAT`

### 2.1 Architectural Comparison Matrix

| Property | `networkingMode=NAT` (Legacy Default) | `networkingMode=mirrored` (WSL 2.0+ / Win11) | Failure Mode / Vulnerability |
| :--- | :--- | :--- | :--- |
| **Virtual Switch** | Hyper-V internal virtual switch (`172.x.y.z/20`) | Hyper-V Virtual Filtering Platform (VFP) L2/L3 mirror | NAT IP is isolated; mirrored shares host L2/L3 stack |
| **IPv6 Support** | Broken / unrouted in most setups | Native dual-stack IPv4 + IPv6 | In NAT, IPv6 outbound is silently dropped |
| **VPN Compatibility** | **CATASTROPHIC**: VPN routes drop `172.x` packets; WSL goes completely offline | **EXCELLENT**: WSL uses host adapters; routes over VPN tunnel | Mirrored VPNs may still enforce firewall rules or drop broadcast |
| **Windows Firewall** | Bypasses host firewall rules in many cases | **APPLIES**: Windows Defender Firewall filters WSL packets | In mirrored mode, `firewall=true` can silently block Linux traffic |
| **Port Conflicts** | Isolated: Linux `0.0.0.0:80` does not collide with Windows `0.0.0.0:80` | **DIRECT COLLISION**: Linux cannot bind to ports already used by Windows | IIS, BranchCache, Skype, Teams on Windows block Linux `bind()` |
| **Localhost Access** | Requires `wslhost.exe` portproxy; fails after sleep/resume | Native shared loopback (`127.0.0.1` and `::1`) | Portproxy desync in NAT; IPv4 vs IPv6 loopback mismatch in mirrored |
| **OS Compatibility** | Windows 10 (Build 19041+) and Windows 11 | Windows 11 22H2 (Build 22621+) only | Configuring mirrored on Win10 causes boot failure (`0x80070057`) |

### 2.2 Deep Failure Analysis

#### Failure 1.1: The NAT Mode VPN Blackhole
In NAT mode, WSL's `eth0` receives an IP from Hyper-V's dynamic internal DHCP pool (typically `172.18.x.x` to `172.31.x.x`). When the host connects to an enterprise VPN (Cisco AnyConnect, Palo Alto GlobalProtect, Zscaler Client Connector):
- The VPN driver updates the Windows routing table with high-metric default routes.
- The VPN driver enforces strict host adapter binding or egress filtering.
- Packets from the Hyper-V virtual adapter (`172.x.y.z`) are either not forwarded through the virtual adapter, or the VPN tunnel gateway discards them because the source IP does not match the assigned VPN IP (anti-spoofing / RPF check).
- **Result:** WSL loses 100% of outbound Internet connectivity the moment VPN connects.

#### Failure 1.2: The Mirrored Mode Firewall Trap
In Windows 11, setting `networkingMode=mirrored` enables Hyper-V Virtual Filtering Platform. However, WSL defaults to `firewall=true` in mirrored mode. This causes Windows Defender Firewall to filter guest Linux traffic:
- Enterprise GPOs often enforce "Block all outbound traffic not matching an approved rule".
- Standard Windows Defender Firewall rules allow `wsl.exe` and `wslhost.exe`, but Hyper-V firewall filtering applies at the virtual network adapter level.
- Outbound connections from new Linux binaries or non-standard ports can be dropped silently without logging in Linux `dmesg`.

#### Failure 1.3: Port Binding Collisions on `0.0.0.0`
In mirrored mode, Linux network interfaces mirror the Windows host. If a Windows service binds to `0.0.0.0:80` (e.g. World Wide Web Publishing Service / IIS, or Windows BranchCache service on port 80/443), an Omarchy web server (Caddy, Nginx, or Vite) attempting to bind to `0.0.0.0:80` receives `EADDRINUSE` (`Errno 98`).

#### Failure 1.4: Dual-Stack Localhost Mismatch
When a Node.js/Vite or Python development server binds to IPv4 `127.0.0.1:3000`, modern Windows browsers resolve `localhost` via `hosts` / DNS to IPv6 `::1` first. In mirrored mode, if `hostAddressLoopback=true` is not set or if the service only bound to IPv4, Windows requests to `http://localhost:3000` receive immediate connection refused (`ECONNREFUSED`).

---

## 3. Attack Angle 2: `dnsTunneling=true`, `autoProxy=true`, and `systemd-resolved`

### 3.1 The Three-Way Resolver Tug-of-War

WSL2 and Arch Linux implement two conflicting DNS management paradigms:

```
[ WSL Initialization (wsl.exe / init) ]
  ├── If generateResolvConf = true:
  │     Overwrites /etc/resolv.conf with static nameserver (e.g. 10.255.255.254 or 172.x.x.1)
  │     UNLINKS any symlink to /run/systemd/resolve/stub-resolv.conf!
  │
  └── If generateResolvConf = false:
        Does NOT touch /etc/resolv.conf
        Leaves system with NO DNS configuration unless systemd-resolved receives DHCP/uplink

[ systemd-resolved.service ]
  ├── Manages /run/systemd/resolve/stub-resolv.conf (listening on 127.0.0.53:53)
  ├── Expects uplink DNS servers from DHCP (systemd-networkd) or NetworkManager
  └── BUT WSL's virtual network interface eth0 DOES NOT run DHCP!
        Result: systemd-resolved has 0 DNS servers configured -> Instant SERVFAIL!
```

### 3.2 Detailed Breakdown of Conflicts

#### Failure 2.1: `dnsTunneling=true` with Default `systemd-resolved`
When `dnsTunneling=true` is set in `.wslconfig`:
- Windows creates a virtual DNS proxy exposed inside Linux at `10.255.255.254` (or host link-local address).
- DNS queries sent to this IP are redirected over a virtualization socket directly to the Windows DNS Client API (`DnsQuery_W`). This cleanly bypasses VPN routing restrictions and split-horizon DNS issues.
- **The Catch:** If `systemd-resolved` is enabled in Omarchy, and `/etc/resolv.conf` is a symlink to `/run/systemd/resolve/stub-resolv.conf`, applications query `127.0.0.53`. `systemd-resolved` has NO uplink servers configured because WSL init did not configure `systemd-resolved` via DBus.
- If WSL init is allowed to overwrite `/etc/resolv.conf` (`generateResolvConf=true`), it breaks the symlink. Applications query `10.255.255.254` directly. But when `systemd-resolved` or a package update runs, or when software uses NSS `nss-resolve`, resolution breaks or flaps unpredictably.

#### Failure 2.2: DNSSEC Validation Failure on Enterprise Networks
`systemd-resolved` defaults to `DNSSEC=allow-downgrade`. In corporate environments:
- Corporate DNS firewalls (Infoblox, Cisco Umbrella, Zscaler) intercept DNS queries on UDP/TCP port 53.
- Corporate resolvers rewrite responses for internal domains and do not return valid DNSSEC RRSIG records.
- When `systemd-resolved` queries public domains (like `archlinux.org`), the enterprise proxy returns an unauthenticated response or strips the DNSSEC header.
- `systemd-resolved` treats this as a DNS spoofing attack, marks the zone as bogus, and returns `SERVFAIL` to `pacman` and `curl`.

#### Failure 2.3: MulticastDNS and LLMNR Clashes
In mirrored networking mode, Linux shares network ports with Windows. `systemd-resolved` enables `LLMNR=yes` (port 5355) and `MulticastDNS=yes` (port 5353) by default. Windows already listens on port 5355 and 5353 on the host. When `systemd-resolved` starts in mirrored mode, it logs bind errors or competes with the Windows host stack for multicast discovery.

#### Failure 2.4: `autoProxy=true` and the SSL MITM Certificate Blackhole
Setting `autoProxy=true` instructs WSL to mirror HTTP proxy settings from Windows WinINet to Linux.
However, enterprise proxies (Zscaler, Palo Alto Networks, BlueCoat) perform SSL/TLS Deep Packet Inspection:
1. The proxy terminates the TLS handshake from `pacman` or `curl`.
2. The proxy re-encrypts traffic using the company's internal Enterprise Root CA.
3. Upstream Arch Linux ships Mozilla's CA bundle in `/etc/ca-certificates/extracted/ca-bundle.trust.crt`. It does NOT contain the corporate Root CA.
4. `pacman -Syu` fails immediately with:
   ```
   error: failed retrieving file ... SSL: certificate verify failed: self-signed certificate in certificate chain
   ```
5. Setting `autoProxy=true` without automated Windows Root CA synchronization actually **accelerates failure**, routing all Linux traffic into an SSL inspection gateway that Arch Linux inherently distrusts!

---

## 4. Attack Angle 3: Container Engine Coexistence (Docker & Rootless Podman)

### 4.1 Root Cause of Container Network Failures

Running Docker (`dockerd`) or rootless Podman inside Omarchy-WSL introduces secondary virtual bridges into the kernel network stack:

```
+-------------------------------------------------------------------------+
| OMARCHY-WSL KERNEL                                                      |
|                                                                         |
|  Mirrored Host Adapters: [eth0 / loopback0] (Host IPs / VPN IPs)        |
|                                                                         |
|  Container Bridges:      [docker0 / 172.17.0.0/16]                     |
|                          [podman0 / 10.88.0.0/16]                       |
+-------------------------------------------------------------------------+
```

### 4.2 Failure Scenarios

#### Failure 3.1: Docker Bridge Subnet Collision with Corporate / VPN Subnets
The default Docker bridge `docker0` claims `172.17.0.0/16`. The secondary pools claim `172.18.0.0/16` through `172.31.0.0/16`.
- In NAT mode: WSL's own gateway often sits in `172.18.x.x` or `172.19.x.x`. If Docker allocates an overlapping subnet, Linux kernel routing routes host gateway traffic to the local `docker0` bridge. Host connectivity dies instantly.
- In Mirrored mode: Corporate intranets and VPNs heavily utilize the `172.16.0.0/12` and `10.0.0.0/8` private address space. When Docker claims `172.17.0.0/16`, any corporate server or intranet git remote residing in that IP range becomes unreachable from Omarchy.

#### Failure 3.2: Iptables / Nftables Filter Rule Contamination
`dockerd` aggressively writes iptables rules (`iptables=true` in `daemon.json`):
- It adds `POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE`.
- In mirrored mode, where Linux interfaces directly mirror host physical adapters, Docker's default iptables rules can intercept or alter host-bound packets.
- Inbound container port mapping (`-p 8080:8080`) binds `0.0.0.0:8080` on the mirrored interface. This exposes the container port directly onto the physical LAN / Wi-Fi network of the host machine, violating enterprise security policies.

#### Failure 3.3: Rootless Podman `pasta` Gateway Resolution
Modern Podman (v4.4+) uses `pasta` (user-mode networking) for rootless containers:
- `pasta` attempts to copy the default route and IP from the host's primary interface (`eth0`).
- In mirrored mode or under certain VPN states, Linux has multiple default routes or special policy routing tables configured by WSL.
- `pasta` fails to detect a valid default gateway and aborts container spawn with:
  `Error: pasta failed with exit code 1: couldn't find default route`.

---

## 5. Attack Angle 4: Pacman Mirror Selection and First-Time Setup Behind Firewalls/VPNs

### 5.1 The `reflector` Catastrophe

Many Arch Linux setup scripts invoke `reflector` during bootstrap or first boot to dynamically rank mirrors by speed:
```bash
reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
```

**Adversarial Failure Mechanism:**
1. `reflector` tests mirror latency using ICMP `ping` packets.
2. In 95% of corporate networks and VPNs, ICMP echo requests are dropped by the firewall or VPN policy.
3. Every single mirror probed reports 100% packet loss.
4. `reflector` either hangs for up to 10 minutes or errors out.
5. If piped directly to `/etc/pacman.d/mirrorlist`, **it writes an empty file (0 bytes)**.
6. The next `pacman -Sy` produces:
   ```
   error: failed to synchronize all databases (no servers configured for repository)
   ```
7. First-time setup / OOBE is completely bricked, requiring manual terminal surgery from a novice user.

### 5.2 Pacman Connection Timeout Cascades

Pacman's internal downloader uses `libcurl`. By default:
- If a mirror in `mirrorlist` is blocked by a corporate firewall or drops SYN packets, `curl` waits up to 300 seconds (5 minutes) before timing out and trying the next mirror.
- If `/etc/pacman.d/mirrorlist` lists 10 geo-distributed mirrors and 4 are blocked or unresponsive behind a VPN, `pacman -Syu` will hang for 20 minutes before making progress.

---

## 6. Attack Angle 5: Localhost Port Forwarding and Windows Interop

### 6.1 Port Binding and Unprivileged Ports
In Linux, ports below 1024 are privileged. A developer running a local Caddy, Nginx, or Docker web server on port 80 or 443 must run as root or set `CAP_NET_BIND_SERVICE`.
In WSL development, users run as unprivileged `aqua` (UID 1000).
- If `aqua` cannot bind to port 80/443 without sudo, local reverse proxies fail to start.
- Sysctl mitigation: `net.ipv4.ip_unprivileged_port_start = 0`.

### 6.2 Host Interop and Path Contamination
WSL provides `appendWindowsPath = true` by default in `/etc/wsl.conf`.
- **The Vulnerability:** Appending Windows `%PATH%` inserts hundreds of Windows directories containing executables with spaces, slow 9p/drvfs metadata lookups, and colliding binaries (`find.exe`, `sort.exe`, `bash.exe` from Git for Windows).
- **The Solution:** Set `appendWindowsPath = false` in `/etc/wsl.conf` to guarantee sub-millisecond shell startup and zero binary collisions.
- **The Resulting Problem:** Without Windows paths, calling `cmd.exe`, `powershell.exe`, or launching Windows Terminal fails unless curated, high-speed symlink shims are installed in `/usr/lib/omarchy-wsl/bin`.

---

## 7. The Unified Architecture Solution

To solve all 5 attack angles simultaneously, Omarchy-WSL implements an **Adversarially Resilient Network Subsystem**:

```
+-----------------------------------------------------------------------------+
|                          OMARCHY-WSL ARCHITECTURE                           |
|                                                                             |
|  1. HOST LEVEL: tools/generate-wslconfig.ps1                                |
|     - Detects Windows 11 build (mirrored + dnsTunneling + autoProxy)        |
|     - Gracefully falls back to NAT on Windows 10                            |
|     - Configures hostAddressLoopback=true, firewall=true                    |
|                                                                             |
|  2. GUEST KERNEL: wsl/sysctl.d/99-zz-omarchy-wsl-network.conf               |
|     - Loose reverse path filtering (rp_filter=2) for VPN multi-homing        |
|     - Unprivileged port binding (ip_unprivileged_port_start=0)              |
|     - Deep socket queues (somaxconn=4096, tcp_fastopen=3)                   |
|                                                                             |
|  3. DNS SUBSYSTEM: bin/omarchy-dns-sync & systemd-resolved drop-in          |
|     - wsl.conf: generateResolvConf = false                                  |
|     - systemd-resolved: DNSSEC=no, LLMNR=no, MulticastDNS=no               |
|     - omarchy-dns-sync: dynamically discovers host DNS (tunneling/NAT)       |
|       and injects uplink servers into systemd-resolved via resolvectl        |
|                                                                             |
|  4. PROXY & CA TRUST: bin/omarchy-ca-sync & bin/omarchy-proxy-sync          |
|     - Extracts Windows Enterprise Root CAs -> /etc/ca-certificates/trust-.. |
|     - Automatically updates system trust store (eliminates SSL MITM errors) |
|     - Injects proxy environment variables into systemd and shell profiles   |
|                                                                             |
|  5. PACMAN RESILIENCE: wsl/pacman/pacman.conf & bin/omarchy-mirror-sync     |
|     - Strict 5s connect timeout (--connect-timeout 5 --max-time 60)         |
|     - Ping-less HTTP/HTTPS metadata probing (never uses ICMP ping)          |
|     - Multi-tier GeoDNS mirrorlist that CANNOT be wiped or corrupted        |
|                                                                             |
|  6. CONTAINER SAFEGUARD: wsl/docker/daemon.json & wsl/podman/containers.conf|
|     - Subnet pool: 198.18.0.0/16 (RFC 2544 benchmark space, zero collision) |
|     - MTU clamping: 1420 (immune to VPN encapsulation packet drops)         |
|     - Safe bridge isolation                                                 |
|                                                                             |
|  7. DIAGNOSTICS: bin/omarchy-netdoctor                                      |
|     - Automated adversarial validation and self-healing CLI                 |
+-----------------------------------------------------------------------------+
```

This ensures that whether a developer is on a coffee-shop Wi-Fi, an isolated airline network, or behind a bank's corporate GlobalProtect VPN with SSL MITM inspection, Omarchy-WSL boots smoothly, resolves DNS without delay, and executes package updates cleanly.
