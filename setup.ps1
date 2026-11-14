# windows-setup: bootstrap a fresh Windows box for remote control over Tailscale + OpenSSH.
#
#   $env:TSKEY='tskey-auth-...'; irm https://raw.githubusercontent.com/dxstn26/windows-setup/main/setup.ps1 | iex
#
# Run in an ADMIN PowerShell. TSKEY is optional (without it, a login URL is printed).
# Env knobs: TSKEY, TS_HOSTNAME, GH_KEYS_USER (default dxstn26), SKIP_SCOOP=1

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this in an elevated (Administrator) PowerShell.' }

$keysUser = if ($env:GH_KEYS_USER) { $env:GH_KEYS_USER } else { 'dxstn26' }
$tmp = Join-Path $env:TEMP 'windows-setup'
New-Item -ItemType Directory -Force $tmp | Out-Null

# ---------------------------------------------------------------- OpenSSH server
Step 'OpenSSH Server'
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    try {
        Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
    } catch { Write-Host "Windows capability failed ($($_.Exception.Message)); using GitHub MSI" }
}
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    $rel = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest' -Headers @{ 'User-Agent' = 'windows-setup' }
    $asset = $rel.assets | Where-Object name -like 'OpenSSH-Win64-*.msi' | Select-Object -First 1
    $msi = Join-Path $tmp $asset.name
    Invoke-WebRequest $asset.browser_download_url -OutFile $msi
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn" -Wait
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}
Set-Service sshd -StartupType Automatic
Start-Service sshd

# Default shell = PowerShell
$ps = (Get-Command powershell.exe).Source
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $ps -PropertyType String -Force | Out-Null

# Firewall: only reachable from the tailnet (CGNAT range), not the public internet
Get-NetFirewallRule -Name 'sshd-tailnet' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue | Disable-NetFirewallRule
New-NetFirewallRule -Name 'sshd-tailnet' -DisplayName 'OpenSSH (Tailscale only)' -Direction Inbound `
    -Protocol TCP -LocalPort 22 -Action Allow -RemoteAddress '100.64.0.0/10' -Profile Any | Out-Null

# Authorized keys: pulled from github.com/<user>.keys (admin accounts use administrators_authorized_keys)
Step "Authorizing SSH keys from github.com/$keysUser.keys"
$keys = (Invoke-RestMethod "https://github.com/$keysUser.keys").Trim()
if (-not $keys) { throw "No public keys found for $keysUser" }
$akf = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
New-Item -ItemType Directory -Force (Split-Path $akf) | Out-Null
[IO.File]::WriteAllText($akf, $keys + "`n", (New-Object Text.UTF8Encoding $false))
icacls.exe $akf /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null

# ---------------------------------------------------------------- Tailscale
Step 'Tailscale'
$tsExe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
if (-not (Test-Path $tsExe)) {
    $msi = Join-Path $tmp 'tailscale.msi'
    Invoke-WebRequest 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi' -OutFile $msi
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn TS_NOLAUNCH=1" -Wait
}
Start-Service Tailscale -ErrorAction SilentlyContinue
$hn = if ($env:TS_HOSTNAME) { $env:TS_HOSTNAME } else { ('win-' + $env:COMPUTERNAME).ToLower() }
$upArgs = @('up', '--unattended', "--hostname=$hn", '--accept-routes=false')
if ($env:TSKEY) { $upArgs += "--authkey=$($env:TSKEY)" }
Write-Host ($(if ($env:TSKEY) { 'Joining tailnet with auth key...' } else { 'No TSKEY set: open the login URL below on any device.' }))
& $tsExe @upArgs
$ip = (& $tsExe ip -4 | Select-Object -First 1)

# ---------------------------------------------------------------- Scoop + git
if ($env:SKIP_SCOOP -ne '1') {
    Step 'Scoop + git'
    $scoopShim = Join-Path $env:USERPROFILE 'scoop\shims\scoop.ps1'
    if (-not (Test-Path $scoopShim)) {
        Invoke-Expression "& {$(Invoke-RestMethod https://get.scoop.sh)} -RunAsAdmin"
    }
    $env:Path += ";$env:USERPROFILE\scoop\shims"
    scoop install git 7zip
}

Step 'Done'
Write-Host "Host : $hn"
Write-Host "IP   : $ip"
Write-Host "User : $env:USERNAME"
Write-Host "From the Mac:  ssh $env:USERNAME@$hn   (or $ip)" -ForegroundColor Green
