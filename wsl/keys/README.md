# Vendored public keys

The image build trusts nothing it downloads until a signature checks out
against one of these keys. They are vendored, not fetched from a keyserver, so
a keyserver outage or a poisoned key cannot change what the build trusts. Each
fingerprint is pinned again in `upstream.lock`, and the build refuses a key
file whose fingerprint differs (`build/lib.sh: import_pinned_key`).

| File | Fingerprint | Owner | Verifies |
|------|-------------|-------|----------|
| `archlinuxarm-build-system.asc` | `68B3537F39A313B3E574D06777193F152BDBE6A6` | Arch Linux ARM Build System `<builder@archlinuxarm.org>` (RSA) | `ArchLinuxARM-aarch64-latest.tar.gz.sig` (Stage 0, arm64) |
| `archlinux-release-pierre-schmitz.asc` | `3E80CA1A8B89F69CBA57D98A76A5EF9054449A5C` | Pierre Schmitz `<pierre@archlinux.org>` (Ed25519), Arch Linux release engineering | `archlinux-bootstrap-x86_64.tar.zst.sig` (Stage 0, amd64) |
| `omarchy.asc` | `40DFB630FF42BCFFB047046CF0134EE680CAC571` | Omarchy `<pkgs@omarchy.org>` (Ed25519) | every package in `[omarchy]` (`https://pkgs.omarchy.org/stable/$arch`) |

Provenance

- `omarchy.asc` is the ASCII-armoured export of `usr/share/pacman/keyrings/omarchy.gpg`
  from `omarchy-keyring-20251027-1-any.pkg.tar.zst` (file sha256
  `15d6aac4…b707de`). That keyring package carries a good signature from the
  same key on both `aarch64` and `x86_64`.
- `archlinuxarm-build-system.asc` is the key Arch Linux ARM publishes for its
  release tarballs. It is the same file the original engine build used.
- `archlinux-release-pierre-schmitz.asc` is a minimal export (`export-minimal`)
  of the key that signs the current `iso/latest` bootstrap tarball. The issuer
  fingerprint subpacket of the 2026-11-01 `.sig` names exactly this key.

After the base system is installed, pacman's own keyrings take over:
`archlinuxarm-keyring` / `archlinux-keyring` for distribution packages and
`omarchy-keyring` for `[omarchy]`. The shipped image contains no
`/etc/pacman.d/gnupg`. `omarchy-pacman-init.service` creates a keyring with a
unique local master key on first boot.

To rotate a key, replace the file and update its fingerprint in
`upstream.lock` in the same commit. `tests/test_upstream_lock.py` fails when
the two disagree.
