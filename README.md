Windows-setup | nothing here so you do not need to look what inside

```powershell
irm https://raw.githubusercontent.com/dxstn26/windows-setup/main/setup.ps1 | iex
```

Undo (add `$env:FULL='1';` in front to also remove Rust, Scoop and the Build Tools):

```powershell
irm https://raw.githubusercontent.com/dxstn26/windows-setup/main/cleanup.ps1 | iex
```
