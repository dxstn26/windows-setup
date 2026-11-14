# windows-setup

One-paste bootstrap for fresh cloud Windows PCs so you can SSH in from the Mac using [tailcat](https://github.com/tailscale/tailcat) (Tailscale's WireGuard + NAT traversal, no account, no control plane).

## On the Windows box (PowerShell, admin NOT required)

```powershell
irm https://raw.githubusercontent.com/dxstn26/windows-setup/main/setup.ps1 | iex
```

From **cmd**:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/dxstn26/windows-setup/main/setup.ps1 | iex"
```

It prints a line like `tailcat ssh <user>@tcXXXX...`.

## On the Mac (one time)

```sh
brew install tailcat
```

`~/.ssh/config` (already set up on this Mac) so ssh offers the right key:

```
Host tc* tailcat-*
    IdentityFile ~/.ssh/id_ed25519_github_dxstn26
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
```

Then paste the printed command: `tailcat ssh <user>@<tc-address>`.

## What the script does

- Downloads the latest tailcat Windows build to `%LOCALAPPDATA%\tailcat` (no installer, no admin).
- Creates a saved server key, so the address stays the same across reboots/restarts.
- Runs `tailcat serve --ssh-authorized-keys=dxstn26@github ssh` hidden, auto-restarting, and registers it to start at logon (scheduled task, falling back to the HKCU Run key). Only keys from `github.com/dxstn26.keys` can log in.
- Installs Scoop + `git` + `7zip` (skip with `$env:SKIP_SCOOP='1'`).

Knobs: `GH_KEYS_USER`, `SKIP_SCOOP=1`, `FRESH_KEY=1` (rotate the address).

## Notes

- Outbound-only: nothing listens on the public internet. The tailcat address embeds a pre-shared key, so treat it as a secret (don't publish it). SSH still requires your key either way.
- Tailcat's SSH server is built in (PowerShell/cmd shell as the logged-in user), so OpenSSH is not needed.
- The Windows user must stay logged in (cloud PCs usually auto-logon) because the task runs at logon.
