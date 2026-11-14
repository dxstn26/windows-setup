# windows-setup: one paste on a fresh Windows box -> SSH in from the Mac over tailcat.
#
#   irm https://raw.githubusercontent.com/dxstn26/windows-setup/main/setup.ps1 | iex
#
# No admin, no account, no auth key, no OpenSSH install: tailcat (github.com/tailscale/tailcat)
# runs a userspace WireGuard tunnel + built-in SSH server, outbound-only (works behind NAT).
# Env knobs: GH_KEYS_USER (default dxstn26), SKIP_SCOOP=1, SKIP_RUST=1, FRESH_KEY=1 (rotate the address)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'
function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }

$keysUser = if ($env:GH_KEYS_USER) { $env:GH_KEYS_USER } else { 'dxstn26' }
$dir = Join-Path $env:LOCALAPPDATA 'tailcat'
$exe = Join-Path $dir 'tailcat.exe'
$log = Join-Path $dir 'serve.log'
$run = Join-Path $dir 'run.ps1'
New-Item -ItemType Directory -Force $dir | Out-Null

# ---------------------------------------------------------------- stop old instance
Get-CimInstance Win32_Process -Filter "Name='tailcat.exe'" -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*tailcat\run.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep 1

# ---------------------------------------------------------------- install tailcat
Step 'Installing tailcat'
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
$rel = Invoke-RestMethod 'https://api.github.com/repos/tailscale/tailcat/releases/latest' -Headers @{ 'User-Agent' = 'windows-setup' }
$asset = $rel.assets | Where-Object name -like "tailcat_*_windows_$arch.zip" | Select-Object -First 1
if (-not $asset) { throw "No Windows $arch build in release $($rel.tag_name)" }
$zip = Join-Path $env:TEMP $asset.name
Invoke-WebRequest $asset.browser_download_url -OutFile $zip
Expand-Archive $zip -DestinationPath $dir -Force
Remove-Item $zip -Force
if (-not (Test-Path $exe)) { $exe = (Get-ChildItem $dir -Recurse -Filter tailcat.exe | Select-Object -First 1).FullName }
Write-Host "tailcat $($rel.tag_name) -> $exe"

# ---------------------------------------------------------------- stable address (saved key)
Step 'Server key'
if ($env:FRESH_KEY -eq '1') { & $exe genkey --delete --key=default 2>$null | Out-Null }
$have = (& $exe genkey --list 2>&1 | Out-String) -match 'default'
if (-not $have) { & $exe genkey --key=default --fixed-region 2>&1 | Out-Null }

# ---------------------------------------------------------------- launcher (auto-restart) + autostart
Step 'Autostart'
@"
`$ErrorActionPreference = 'Continue'
while (`$true) {
    & '$exe' serve --ssh-authorized-keys=$keysUser@github ssh 2> '$log'
    Start-Sleep 5
}
"@ | Set-Content -Path $run -Encoding UTF8

$psArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$run`""
try {
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs
    $trg = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
    Register-ScheduledTask -TaskName 'tailcat-ssh' -Action $act -Trigger $trg -Settings $set -Force | Out-Null
    Write-Host 'Scheduled task tailcat-ssh registered (runs at logon).'
} catch {
    Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'tailcat-ssh' -Value "powershell.exe $psArgs"
    Write-Host 'Scheduled task unavailable; added HKCU Run entry instead.'
}

Remove-Item $log -ErrorAction SilentlyContinue
Start-Process powershell.exe -ArgumentList $psArgs -WindowStyle Hidden

# ---------------------------------------------------------------- show address
Step 'Waiting for tailcat address'
$addr = $null
for ($i = 0; $i -lt 30 -and -not $addr; $i++) {
    Start-Sleep 1
    if (Test-Path $log) {
        $m = [regex]::Match((Get-Content $log -Raw -ErrorAction SilentlyContinue), 'tc[A-Za-z0-9_-]{20,}')
        if ($m.Success) { $addr = $m.Value }
    }
}
if (-not $addr) { Write-Host "No address yet; check $log" -ForegroundColor Yellow }
if ($addr) {
Write-Host "`nUser    : $env:USERNAME"
Write-Host "Address : $addr"
Write-Host "`nFrom the Mac:" -ForegroundColor Green
Write-Host "  tailcat ssh $env:USERNAME@$addr" -ForegroundColor Green
}

# ---------------------------------------------------------------- scoop + git (optional)
if ($env:SKIP_SCOOP -ne '1') {
    Step 'Scoop + git'
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not (Test-Path (Join-Path $env:USERPROFILE 'scoop\shims\scoop.ps1'))) {
        $extra = if ($isAdmin) { ' -RunAsAdmin' } else { '' }
        Invoke-Expression "& {$(Invoke-RestMethod https://get.scoop.sh)}$extra"
    }
    $env:Path += ";$env:USERPROFILE\scoop\shims"
    scoop install git 7zip
}

# ---------------------------------------------------------------- Rust + Bevy (optional, slow: runs after the address is shown)
if ($env:SKIP_RUST -ne '1') {
    Step 'Rust (rustup) + Bevy prerequisites'
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    # MSVC linker (Bevy needs it on the default msvc toolchain)
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $hasVC = (Test-Path $vswhere) -and (& $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
    if (-not $hasVC) {
        if ($isAdmin) {
            Write-Host 'Installing Visual Studio Build Tools (C++), several GB, takes a while...'
            $bt = Join-Path $env:TEMP 'vs_BuildTools.exe'
            Invoke-WebRequest 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -OutFile $bt
            Start-Process $bt -Wait -ArgumentList '--quiet --wait --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
        } else {
            Write-Host 'No MSVC Build Tools and not admin: re-run this in an admin PowerShell to install them (needed to link Bevy).' -ForegroundColor Yellow
        }
    }
    if (-not (Test-Path "$env:USERPROFILE\.cargo\bin\rustup.exe")) {
        $ri = Join-Path $env:TEMP 'rustup-init.exe'
        Invoke-WebRequest 'https://win.rustup.rs/x86_64' -OutFile $ri
        & $ri -y --default-toolchain stable --profile minimal
    }
    $env:Path += ";$env:USERPROFILE\.cargo\bin"
    rustup component add clippy rustfmt 2>&1 | Out-Null
    # Bevy starter project, dependencies prefetched (first build is slow; dynamic_linking speeds up dev rebuilds)
    $proj = Join-Path $env:USERPROFILE 'bevy-hello'
    if (-not (Test-Path $proj)) {
        cargo new $proj --bin 2>&1 | Out-Null
        Push-Location $proj
        cargo add bevy --features dynamic_linking 2>&1 | Out-Null
        cargo fetch 2>&1 | Out-Null
        Pop-Location
    }
    Write-Host "Rust ready. Bevy starter: $proj  (cd there, then: cargo run)"
}
