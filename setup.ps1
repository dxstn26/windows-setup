# windows-setup: one paste on a fresh Windows box -> SSH in from the Mac over tailcat.
#
#   irm https://raw.githubusercontent.com/dxstn26/windows-setup/main/setup.ps1 | iex
#
# No admin, no account, no auth key, no OpenSSH install: tailcat (github.com/tailscale/tailcat)
# runs a userspace WireGuard tunnel + built-in SSH server, outbound-only (works behind NAT).
# Env knobs: GH_KEYS_USER (default dxstn26), FRESH_KEY=1 (rotate the address),
#            SKIP_SCOOP=1, SKIP_RUST=1, SKIP_BEVY=1 (no starter project),
#            DEFENDER_EXCLUDE=1 (admin only: keep Defender out of the Rust folders)
# Run it in an admin PowerShell if the box has no MSVC Build Tools: Rust cannot link without them.
# Undo everything with cleanup.ps1.

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
# tailcat reports on stderr; under 'Stop', Windows PowerShell 5.1 would treat that as a failure.
$ErrorActionPreference = 'Continue'
if ($env:FRESH_KEY -eq '1') { & $exe genkey --delete --key=default 2>&1 | Out-Null }
$have = (& $exe genkey --list 2>&1 | Out-String) -match 'default'
if (-not $have) {
    & $exe genkey --key=default --fixed-region 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "tailcat genkey failed with exit code $LASTEXITCODE" }
}
$ErrorActionPreference = 'Stop'

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

# From here on the tools are native programs that write normal progress to stderr.
# Under 'Stop', Windows PowerShell 5.1 turns that into a terminating error, so check exit codes instead.
$ErrorActionPreference = 'Continue'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$problems = @()

# ---------------------------------------------------------------- scoop + git + gh (optional)
if ($env:SKIP_SCOOP -ne '1') {
    Step 'Scoop + git + gh'
    # Scoop and its shims are scripts: a fresh Windows refuses to run them until the user's policy allows it.
    if ((Get-ExecutionPolicy) -notin 'Unrestricted', 'RemoteSigned', 'Bypass') {
        Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        Write-Host 'Execution policy for this user set to RemoteSigned.'
    }
    if (-not (Test-Path (Join-Path $env:USERPROFILE 'scoop\shims\scoop.ps1'))) {
        $extra = if ($isAdmin) { ' -RunAsAdmin' } else { '' }
        Invoke-Expression "& {$(Invoke-RestMethod https://get.scoop.sh)}$extra"
    }
    $env:Path += ";$env:USERPROFILE\scoop\shims"
    scoop install git 7zip gh
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { $problems += 'git did not install (scoop)' }
}

# ---------------------------------------------------------------- Rust + Bevy (optional, slow: runs after the address is shown)
if ($env:SKIP_RUST -ne '1') {
    Step 'Rust (rustup) + Bevy prerequisites'
    # MSVC linker (Bevy needs it on the default msvc toolchain)
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $hasVC = (Test-Path $vswhere) -and (& $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
    if (-not $hasVC) {
        if ($isAdmin) {
            Write-Host 'Installing Visual Studio Build Tools (C++), several GB, takes a while...'
            $bt = Join-Path $env:TEMP 'vs_BuildTools.exe'
            Invoke-WebRequest 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -OutFile $bt -ErrorAction Stop
            $p = Start-Process $bt -Wait -PassThru -ArgumentList '--quiet --wait --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
            # 3010 = installed, restart wanted
            if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { $problems += "Visual Studio Build Tools installer exited with $($p.ExitCode)" }
        } else {
            $problems += 'No MSVC Build Tools and not admin: Rust is installed but cannot link. Re-run this in an admin PowerShell.'
        }
    }
    if (-not (Test-Path "$env:USERPROFILE\.cargo\bin\rustup.exe")) {
        $rustArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
        $ri = Join-Path $env:TEMP 'rustup-init.exe'
        Invoke-WebRequest "https://win.rustup.rs/$rustArch" -OutFile $ri -ErrorAction Stop
        & $ri -y --default-toolchain stable --profile minimal
        if ($LASTEXITCODE -ne 0) { $problems += "rustup-init exited with $LASTEXITCODE" }
    }
    $env:Path += ";$env:USERPROFILE\.cargo\bin"
    rustup component add clippy rustfmt
    if ($LASTEXITCODE -ne 0) { $problems += 'rustup could not add clippy and rustfmt' }

    # Real-time scanning of build output slows Rust builds a lot. Opt-in, and admin only.
    if ($env:DEFENDER_EXCLUDE -eq '1') {
        if ($isAdmin) {
            Add-MpPreference -ExclusionPath "$env:USERPROFILE\.cargo", "$env:USERPROFILE\.rustup", "$env:USERPROFILE\src"
            Write-Host "Defender exclusions added: .cargo, .rustup and $env:USERPROFILE\src (clone and build there)."
        } else {
            $problems += 'DEFENDER_EXCLUDE=1 needs an admin PowerShell; no exclusion was added.'
        }
    }

    # Bevy starter project, dependencies prefetched (first build is slow; dynamic_linking speeds up dev rebuilds)
    $proj = Join-Path $env:USERPROFILE 'bevy-hello'
    if ($env:SKIP_BEVY -ne '1' -and -not (Test-Path $proj)) {
        cargo new $proj --bin
        Push-Location $proj
        cargo add bevy --features dynamic_linking
        cargo fetch
        Pop-Location
        Write-Host "Bevy starter: $proj  (cd there, then: cargo run)"
    }
}

# ---------------------------------------------------------------- summary
Step 'Done'
if ($addr) { Write-Host "  tailcat ssh $env:USERNAME@$addr" -ForegroundColor Green }
if ($env:SKIP_SCOOP -ne '1') { Write-Host 'For private repositories, sign in once on this box:  gh auth login   then   gh auth setup-git' }
if ($problems) {
    Write-Host "`nNot finished:" -ForegroundColor Yellow
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
