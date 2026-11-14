# windows-setup

One-paste bootstrap for fresh cloud Windows PCs: OpenSSH server + Tailscale + Scoop + git, so you can SSH in from the Mac over the tailnet.

## Use (admin PowerShell on the Windows box)

```powershell
$env:TSKEY='tskey-auth-XXXX'; irm https://raw.githubusercontent.com/dxstn26/windows-setup/main/setup.ps1 | iex
```

From **cmd** (admin):

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:TSKEY='tskey-auth-XXXX'; irm https://raw.githubusercontent.com/dxstn26/windows-setup/main/setup.ps1 | iex"
```

Then on the Mac: `ssh <windows-user>@win-<computername>` (printed at the end).

## Auth key

Never commit it; this repo is public. Create a reusable, pre-approved, ephemeral key at
<https://login.tailscale.com/admin/settings/keys> and paste it only in the command. Omit `TSKEY` to get a login URL instead.

## What it does

- Installs OpenSSH Server (Windows capability, falls back to the Win32-OpenSSH MSI), PowerShell as default shell.
- Firewall: port 22 allowed only from the Tailscale range `100.64.0.0/10`.
- Authorizes the public keys from `github.com/dxstn26.keys` (override with `$env:GH_KEYS_USER`).
- Installs Tailscale and joins with `--unattended` (survives logout/reboot), hostname `win-<computername>`.
- Installs Scoop, then `git` and `7zip` (skip with `$env:SKIP_SCOOP='1'`).

Re-running is safe.
