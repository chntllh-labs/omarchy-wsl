# WSL File System Performance & Disk I/O Architecture

An adversarial deep-dive into WSL file system bottlenecks, protocol translation overheads, and kernel I/O tuning across the Windows/Linux boundary.

---

## 1. 9P Protocol vs. Virtio-FS: The Virtualization Boundary

### 1.1 The DrvFs 9P Architecture & The Latency Tax
WSL historically exposes Windows NTFS drives (`C:\`, `D:\`) under `/mnt/` using **DrvFs**, implemented atop Linux's `v9fs` client speaking the **9P2000.L** protocol over Hyper-V sockets (`AF_HYPERV` / `vsock`) to `wslhost.exe` on Windows.

9P is a chatty, serialized request-response RPC protocol. Every POSIX filesystem system call executed inside the Linux guest triggers a round-trip RPC across the virtualization boundary:
- `Twalk`: Path resolution walks each directory element individually. Traversing a 10-level deep path (`/mnt/c/Users/.../node_modules/...`) produces 10 serialized RPCs before the file is even addressed.
- `Tgetattr`: Queries POSIX metadata.
- `Tlopen` / `Tread` / `Twrite` / `Tclunk`: Handles file open, I/O in fixed buffers (`msize=65536`), and file close.

#### The Math of 9P Latency Amplification
| Operation | Native ext4 (DRAM Cache) | 9P DrvFs over vsock | Overhead Factor |
| :--- | :--- | :--- | :--- |
| **Inode/Dentry Stat** | ~50 – 100 ns | ~30 – 100 µs | **~500x – 1000x** |
| **Directory Walk (Depth 8)** | ~400 ns | ~250 – 800 µs | **~1000x** |
| **`git status` (50k files)** | ~0.08 s | ~7.5 – 12.0 s | **~100x – 150x** |
| **`cargo check` (clean target)** | ~1.2 s | ~18.4 s | **~15x** |

Every 9P RPC incurs:
1. Guest kernel VFS switch -> `v9fs` driver packet serialization.
2. Hyper-V hypercall / VM-exit context switch to Windows host ring 0.
3. IPC dispatch to Windows user-mode `wslhost.exe`.
4. Win32 filesystem subsystem translation (`NtQueryInformationFile` / `NtReadFile`).
5. Windows Defender (`MsMpEng.exe`) minifilter driver synchronous inspection.
6. Reverse packet marshaling and return context switch back to the guest thread.

### 1.2 Virtio-FS: Capabilities, Limitations, and Production Traps
Virtio-FS replaces the socket-based RPC transport with shared memory regions (DAX - Direct Access) and virtio ring queues:
- Eliminates socket serialization overhead and the 256-byte path length crash present in the Linux kernel `v9fs` driver.
- Direct memory mapping allows zero-copy file reads between host page cache and guest.

#### Production Hazards in WSL (WSL 2.4+ / 3.0+):
1. **The Silent Automount Cascade Drop**: In WSL 2.5–2.7+, if any single drive (e.g. secondary SATA drive, network mount, or USB media) returns error 22 (`EINVAL`) during virtiofs initialization, the WSL core VM silently drops *all* automounts, leaving `/mnt/c` completely missing without logging an error.
2. **Statx EIO Failures**: POSIX extended stat translation across certain Windows metadata paths can throw `EIO`.
3. **Filter Driver Bottleneck Unresolved**: Virtio-FS accelerates guest-to-host IPC, but it **cannot bypass host NTFS locking or Windows Defender scanning**. Accessing files on `/mnt/c` via virtiofs is still 5x–15x slower than native ext4 VHDX.

---

## 2. DrvFs Mount Flags: Mechanics and Pitfalls

### 2.1 Parameter Breakdown
In `/etc/wsl.conf` under `[automount] options`:

```ini
options = "metadata,uid=1000,gid=1000,umask=022,fmask=011,case=off"
```

1. **`metadata`**:
   - Stores POSIX permissions (UID, GID, octal mode) inside NTFS Extended Attributes (`$LXUID`, `$LXGID`, `$LXMOD`, `$LXDEV`).
   - Required for `chmod 600` (SSH keys), script execution bits, and preventing Git from reporting spurious 0777 permission diffs.
   - Cost: Incurs an additional NTFS EA query during file stat.
2. **`uid=1000,gid=1000`**:
   - Binds files lacking metadata directly to the primary user (`aqua`).
   - Eliminates runtime Windows SID-to-POSIX UID lookup overhead.
3. **`umask=022,fmask=011`**:
   - `umask=022`: Sets directory mask to `0755` (`drwxr-xr-x`), ensuring directory traversal.
   - `fmask=011`: Strips the executable bit from regular files (`-rw-r--r--`). Prevents plain source files, text files, and images on Windows drives from erroneously inheriting execute permissions.
4. **`case=off` vs. `case=dir` (The Latency Multiplier)**:
   - `case=dir`: DrvFs queries the NTFS per-directory case sensitivity attribute (`FILE_CASE_SENSITIVE_SEARCH`) on *every single directory traversal*. On large source trees, this doubles the metadata query overhead across vsock.
   - `case=off`: Standardizes case insensitivity globally across mounted drives, eliminating per-directory NTFS attribute queries and preventing Windows native tool corruption.
5. **The `dir_mode=0777` Myth**:
   - `dir_mode` and `file_mode` are SMB/CIFS (`cifs.ko`) mount parameters, **not DrvFs parameters**. DrvFs controls directory permissions via `dmask` and `umask`. Passing `dir_mode` to DrvFs is ignored.

---

## 3. Linux VFS Kernel Sysctl Tuning for Multi-Core / NVMe

High-core processors (Snapdragon Oryon 18-core, AMD Ryzen 16c/32t, Intel Core Ultra) paired with fast PCIe 4.0/5.0 NVMe drives expose severe flaws in default Linux memory flusher heuristics.

### 3.1 The Dirty Page Stall Catastrophe
With 48 GB RAM allocated to WSL:
- Linux defaults: `vm.dirty_background_ratio = 10` (~4.8 GB), `vm.dirty_ratio = 20` (~9.6 GB).
- When a 18-thread compiler (`cargo build -j18`, `make -j18`) runs, dirty pages accumulate rapidly.
- Once dirty pages cross 20%, Linux invokes `throttle_vm_writeout()`. The kernel puts user-space threads to sleep to synchronously flush dirty pages to disk.
- Flushing 9.6 GB across the virtualized SCSI/Hyper-V storage layer creates massive pipeline queuing, causing terminal stutters, Neovim cursor freezing, and tmux unresponsiveness.

### 3.2 The Flusher Remedy
```ini
# /etc/sysctl.d/99-zz-omarchy-wsl-stability.conf
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.dirty_expire_centisecs = 1000
vm.dirty_writeback_centisecs = 250
```
- **`dirty_background_ratio = 5`**: Background kernel writeback threads (`wb_workfn`) activate at 5% dirty threshold (~2.4 GB), continuously streaming writes to NVMe.
- **`dirty_ratio = 10`**: Low synchronous ceiling prevents deep I/O request queues from ever accumulating.
- **`dirty_expire_centisecs = 1000` (10s)** & **`dirty_writeback_centisecs = 250` (2.5s)**: Eliminates 30-second dirty data aging, ensuring small, steady I/O cadence.

### 3.3 Metadata Caching: `vm.vfs_cache_pressure`
- Default: `100`.
- In developer environments with large codebases, dentry and inode lookups dominate `git status`, `ripgrep`, and Neovim LSP indexing.
- Setting `vm.vfs_cache_pressure = 50` prioritizes retaining dentries and inodes in guest RAM over bulk page cache. Subsequent path lookups hit DRAM instantly.
- *Caution*: Never set to `0`, which completely disables slab reclamation and causes OOM panic.

### 3.4 Block Device Readahead: `read_ahead_kb`
- Default on virtual block devices (`/dev/sd*`): `128 KB`.
- For fast NVMe storage reading large compilation artifacts or language models, 128 KB underutilizes PCIe bandwidth.
- Configured via `/etc/tmpfiles.d/wsl-nvme-io.conf`:
  ```
  w /sys/block/sd*/queue/read_ahead_kb - - - - 1024
  w /sys/block/vd*/queue/read_ahead_kb - - - - 1024
  w /sys/block/sd*/queue/nr_requests - - - - 256
  w /sys/block/vd*/queue/nr_requests - - - - 256
  ```
  Expands readahead to 1024 KB (1 MB) and queue depth to 256 requests.

---

## 4. Cross-Boundary Toolchain Impasse (Neovim, Git, LSP)

### 4.1 Inotify vs. ReadDirectoryChangesW
- Linux toolchains (Neovim LSP, Vite, Webpack, Watchman, `cargo-watch`) rely on Linux kernel `inotify`.
- When projects reside under `/mnt/c/`, file modifications occur via the Windows kernel, generating `ReadDirectoryChangesW` events on the host.
- **WSL DrvFs does not bridge host filesystem notifications to guest inotify**.
- Tools fail to receive change notifications and fall back to polling directory trees every 200–500ms.
- Polling 50,000 files across 9P/vsock pins all 18 CPU cores and exhausts I/O bandwidth.

### 4.2 The Storage Topology Law
```
+-------------------------------------------------------------------+
|                        STORAGE BOUNDARY                           |
+-------------------------------------------------------------------+
|   WINDOWS HOST FILESYSTEM (/mnt/c)                                |
|   - Read-only media, document archives, host downloads            |
|   - Windows executables (.exe)                                    |
|   - DO NOT STORE: Git repositories, node_modules, cargo target    |
+-------------------------------------------------------------------+
                                  |
                   [ STRICT PROHIBITION BARRIER ]
                                  v
+-------------------------------------------------------------------+
|   NATIVE EXT4 VHDX (/home/aqua)                                   |
|   - All source code repositories (~/hermes/workspace)             |
|   - Package manager caches (~/.cargo, ~/.npm, ~/.local/share/mise)|
|   - Compilation outputs (target/, build/, dist/)                  |
|   - Language server caches (clangd, rust-analyzer, gopls)         |
|   - Full POSIX semantics, native inotify, microsecond latency     |
+-------------------------------------------------------------------+
```

### 4.3 Windows Access to Linux Ext4
When Windows tools need to view Linux files:
1. **Windows Explorer**: Access via `\\wsl.localhost\Omarchy\home\aqua\...`.
2. **VS Code / Cursor / Zed**: Use the native WSL remote server architecture. The language server and filesystem watcher run natively inside Linux ext4, streaming only UI elements across the socket.
3. **Windows Defender Exclusion**: Exclude `wsl.exe`, `wslhost.exe`, and the `ext4.vhdx` directory from real-time scanning.

---

## 5. Ext4 VHDX Storage Management & The Sparse VHD Trap

### 5.1 Dynamic Expansion & Host Fragmentation
- WSL creates dynamically expanding VHDX files in 32 MB payload blocks.
- Host NTFS metadata must execute synchronous `FileAllocationInformation` transactions when blocks expand.
- Deleting files inside ext4 (`rm -rf`) only clears guest ext4 block bitmaps; host VHDX size does not shrink automatically.

### 5.2 The `sparseVhd=true` Data Corruption Trap
- Setting `sparseVhd=true` enables NTFS sparse hole-punching via `FSCTL_SET_ZERO_DATA` during guest `fstrim`.
- **Critical CVE / Stability Warning (WSL 2.5.6+)**:
  Microsoft officially gated sparse VHD behind `--allow-unsafe` due to reproducible ext4 superblock and journal corruption caused by race conditions during parallel guest writes and host sparse punching.
- Furthermore, sparse hole-punching creates hundreds of thousands of NTFS MFT run extents, severely degrading physical NVMe performance.
- **Production Standard**: Keep `sparseVhd = false`.

### 5.3 Deterministic Safe Compaction Protocol
To reclaim disk space safely without corruption risk:
1. Inside Omarchy Linux:
   ```bash
   sudo fstrim -v /
   ```
2. In Windows PowerShell (Administrative / User):
   ```powershell
   wsl --shutdown
   # Using Hyper-V PowerShell module:
   Optimize-VHD -Path "$env:LOCALAPPDATA\Packages\<DistroPackage>\LocalState\ext4.vhdx" -Mode Full
   # Or using diskpart:
   # select vdisk file="<path>\ext4.vhdx"
   # compact vdisk
   ```

### 5.4 Bare-Metal NVMe Pass-Through (`wsl --mount`)
For workloads requiring maximum PCIe 4.0/5.0 line-rate throughput (>7,000 MB/s, >1M IOPS):
```powershell
# Direct physical drive mount (dedicated NVMe disk)
wsl --mount \\.\PHYSICALDRIVE1 --bare
# Mount partition directly inside Linux
sudo mount -t ext4 -o noatime,commit=60 /dev/sdb /mnt/fast-nvme
```
Bypasses host NTFS, VHDX virtualization, and host caching entirely.
