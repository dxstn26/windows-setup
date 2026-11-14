# windows-setup: undo setup.ps1.
#
#   irm https://raw.githubusercontent.com/dxstn26/windows-setup/main/cleanup.ps1 | iex
#
# Always removes tailcat: its processes, autostart, saved key and folder. After this the box
# cannot be reached with the old address.
# FULL=1 also removes what setup.ps1 installed for development: the Bevy starter, Rust, Scoop
# (with git, 7zip and gh, and the gh sign-in), Defender exclusions, and, in an admin PowerShell,
# the Visual Studio Build Tools. Do not use FULL=1 on a box that had any of these before.

$ErrorActionPreference = 'Continue'
function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$dir = Join-Path $env:LOCALAPPDATA 'tailcat'

if ($env:FULL -eq '1') {
    Step 'Signing out of GitHub'
    if (Get-Command gh -ErrorAction SilentlyContinue) { gh auth logout --hostname github.com 2>$null }

    Step 'Removing the Bevy starter and Rust'
    Remove-Item (Join-Path $env:USERPROFILE 'bevy-hello') -Recurse -Force -ErrorAction SilentlyContinue
    $rustup = "$env:USERPROFILE\.cargo\bin\rustup.exe"
    if (Test-Path $rustup) { & $rustup self uninstall -y }
    Remove-Item "$env:USERPROFILE\.cargo", "$env:USERPROFILE\.rustup" -Recurse -Force -ErrorAction SilentlyContinue

    Step 'Removing Scoop'
    Remove-Item (Join-Path $env:USERPROFILE 'scoop') -Recurse -Force -ErrorAction SilentlyContinue
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath) {
        $kept = ($userPath -split ';' | Where-Object { $_ -and $_ -notlike '*\scoop\shims*' -and $_ -notlike '*\.cargo\bin*' }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $kept, 'User')
    }

    if ($isAdmin) {
        Step 'Removing Defender exclusions'
        Remove-MpPreference -ExclusionPath "$env:USERPROFILE\.cargo", "$env:USERPROFILE\.rustup", "$env:USERPROFILE\src" -ErrorAction SilentlyContinue

        Step 'Removing Visual Studio Build Tools'
        $installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
        $vswhere = Join-Path $installer 'vswhere.exe'
        if (Test-Path $vswhere) {
            & $vswhere -products Microsoft.VisualStudio.Product.BuildTools -property installationPath | ForEach-Object {
                Write-Host "Uninstalling $_ (takes a while)..."
                Start-Process (Join-Path $installer 'setup.exe') -Wait -ArgumentList "uninstall --installPath `"$_`" --quiet --norestart"
            }
        }
    } else {
        Write-Host 'Not admin: Visual Studio Build Tools and Defender exclusions were left in place.' -ForegroundColor Yellow
    }
    Write-Host "Not touched: anything you cloned yourself, such as $env:USERPROFILE\src." -ForegroundColor Yellow
}

# Last, because this may be the connection the script is running over.
Step 'Removing tailcat'
Unregister-ScheduledTask -TaskName 'tailcat-ssh' -Confirm:$false -ErrorAction SilentlyContinue
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'tailcat-ssh' -ErrorAction SilentlyContinue
$exe = Join-Path $dir 'tailcat.exe'
if (Test-Path $exe) { & $exe genkey --delete --key=default 2>$null | Out-Null }
Write-Host 'Done. Stopping tailcat now; an SSH session through it ends here.'
# A detached helper finishes the job, so it still happens when this session dies with tailcat.
$helper = Join-Path $env:TEMP 'tailcat-cleanup.ps1'
@'
Start-Sleep 2
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*tailcat\run.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Get-Process tailcat -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 1
Remove-Item (Join-Path $env:LOCALAPPDATA 'tailcat') -Recurse -Force
Remove-Item $PSCommandPath -Force
'@ | Set-Content -Path $helper -Encoding UTF8
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$helper`""
