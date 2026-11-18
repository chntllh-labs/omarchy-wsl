# distributions/

`DistributionInfo.fragment.json` is Omarchy's entry for Microsoft's WSL
distribution manifest, `distributions/DistributionInfo.json` in
[microsoft/WSL](https://github.com/microsoft/WSL). That manifest is the list
behind `wsl --list --online` and `wsl --install <name>`. The entry uses the
`ModernDistributions` schema for tar-based `.wsl` images: one flavor
(`Omarchy`), one default version, an `Amd64Url` and an `Arm64Url`, each with
`Url` and `Sha256`. Microsoft's validator rejects any other key.

Omarchy is **not** in Microsoft's list today. Until it is, install with
`install/install.ps1` or `wsl --install --from-file Omarchy-<arch>.wsl`.

## Fill in the release values

Both `Sha256` values are all zeros: placeholders, in the format the schema
expects (64 hex digits, optionally prefixed with `0x`). For each release, point
the URLs at the release tag and set the hashes to the ones in that release's
`SHA256SUMS`:

```bash
tag=v4.5.0
base=https://github.com/chntllh-labs/omarchy-wsl/releases/download/$tag
x64=$(awk '$2 == "Omarchy-x86_64.wsl" { print $1 }' SHA256SUMS)
arm=$(awk '$2 == "Omarchy-arm64.wsl" { print $1 }' SHA256SUMS)
jq --arg b "$base" --arg x "0x$x64" --arg a "0x$arm" '
  .ModernDistributions.Omarchy[0].Amd64Url = { Url: "\($b)/Omarchy-x86_64.wsl", Sha256: $x } |
  .ModernDistributions.Omarchy[0].Arm64Url = { Url: "\($b)/Omarchy-arm64.wsl", Sha256: $a }' \
  distributions/DistributionInfo.fragment.json
```

## Validate with Microsoft's script

`distributions/validate-modern.py` in microsoft/WSL is what its pull-request
check runs. It downloads both images, compares the hashes and inspects the tar
(`/etc/wsl-distribution.conf` keys and the files it names, `/etc/wsl.conf`
keys, `/etc/passwd`, `/etc/shadow`, `/bin/sh`, enabled systemd units, WSL1
xattrs). Run it in a throwaway container or VM, since it is third-party code:

```bash
git clone https://github.com/microsoft/WSL && cd WSL
python3 -m venv /tmp/wslcheck && /tmp/wslcheck/bin/pip install -r distributions/requirements.txt
# Merge the "Omarchy" flavor from DistributionInfo.fragment.json into
# distributions/DistributionInfo.json, then:
/tmp/wslcheck/bin/python distributions/validate-modern.py \
  --manifest distributions/DistributionInfo.json --repo-path . --compare-with-branch origin/master
# One image, no manifest (add --arm64 for the ARM64 image):
/tmp/wslcheck/bin/python distributions/validate-modern.py --tar /path/to/Omarchy-x86_64.wsl
```

With placeholder hashes, or before the release exists, it reports errors for
the URLs. That is expected.

To try the entry on a Windows machine first, put the merged manifest in a file
and point WSL at it (elevated PowerShell; WSL 2.4.4 or later accepts
`file://` URLs):

```powershell
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss' -Name DistributionListUrlAppend -Value 'file:///C:/path/to/DistributionInfo.json' -Type String
wsl --list --online   # Omarchy appears; remove the value again when done
```

## Submitting

Open a pull request against microsoft/WSL that adds the `Omarchy` flavor to
`distributions/DistributionInfo.json`, with real URLs and hashes. The WSL team
reviews it; Microsoft lists only distributions that meet its membership
criteria (see "Adding your distribution to wsl --install for all WSL users" in
[Build a custom Linux distribution for WSL](https://learn.microsoft.com/en-us/windows/wsl/build-custom-distro)).

## Why there is no winget package

winget cannot install a `.wsl` image. Its installer manifest schema (checked
up to v1.28.0) allows `InstallerType` msix, msi, appx, exe, zip, inno,
nullsoft, wix, burn, pwa, portable and font; there is no `wsl` type, and none
of the others registers a WSL distribution. The repository therefore ships no
winget manifest. Releases are published on GitHub (images, `SHA256SUMS`, build
provenance attestations and a Sigstore bundle for `SHA256SUMS`), and the
Microsoft manifest above is the channel for `wsl --install Omarchy`.
