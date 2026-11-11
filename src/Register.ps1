param([switch]$Remove)
# Rejestruje SebSandbox w systemie wg install.json: menu kontekstowe (.exe/.msi), skróty, wpis w "Zainstalowane aplikacje".
# -Remove usuwa wszystkie te wpisy. Dotyczy bieżącego użytkownika (HKCU, jego menu Start i pulpit).
$root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgPath = Join-Path $root 'install.json'
$cfg = @{ ContextMenu = $true; StartMenu = $true; Desktop = $false; Version = '1.0' }
try { $j = Get-Content -LiteralPath $cfgPath -Raw -ErrorAction Stop | ConvertFrom-Json; foreach ($k in 'ContextMenu', 'StartMenu', 'Desktop', 'Version') { if ($null -ne $j.$k) { $cfg[$k] = $j.$k } } } catch {}

$script = Join-Path $root 'Start-SebSandbox.ps1'
$icon   = Join-Path $root 'SebSandbox.ico'
if (-not (Test-Path -LiteralPath $icon)) { $icon = 'powershell.exe' }
$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
$startLnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'SebSandbox.lnk'
$deskLnk  = Join-Path ([Environment]::GetFolderPath('Desktop')) 'SebSandbox.lnk'
$uninst   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SebSandbox'

# --- zawsze najpierw sprzątanie (także po starszych wersjach)
foreach ($ext in '.exe', '.msi') {
    foreach ($k in 'SebSandbox', 'SebSandboxNet') {
        $p = "HKCU:\Software\Classes\SystemFileAssociations\$ext\shell\$k"
        if (Test-Path $p) { Remove-Item $p -Recurse -Force }
    }
}
foreach ($l in $startLnk, $deskLnk) { if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force } }
if (Test-Path $uninst) { Remove-Item $uninst -Recurse -Force }
if ($Remove) { return }

# --- menu kontekstowe
if ($cfg.ContextMenu) {
    foreach ($ext in '.exe', '.msi') {
        $k = "HKCU:\Software\Classes\SystemFileAssociations\$ext\shell\SebSandbox"
        New-Item -Path "$k\command" -Force | Out-Null
        Set-ItemProperty -Path $k -Name '(default)' -Value 'Uruchom w piaskownicy'
        Set-ItemProperty -Path $k -Name 'Icon' -Value $icon
        Set-ItemProperty -Path "$k\command" -Name '(default)' -Value "powershell.exe $psArgs -Path `"%1`""
    }
}

# --- skróty (przeciągnięcie pliku na skrót też uruchamia test)
$ws = New-Object -ComObject WScript.Shell
foreach ($pair in @(@($cfg.StartMenu, $startLnk), @($cfg.Desktop, $deskLnk))) {
    if (-not $pair[0]) { continue }
    $l = $ws.CreateShortcut($pair[1])
    $l.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $l.Arguments = $psArgs
    $l.WorkingDirectory = $root
    $l.Description = 'SebSandbox - test programów w Windows Sandbox'
    $l.WindowStyle = 7
    $l.IconLocation = "$icon,0"
    $l.Save()
}

# --- wpis w "Zainstalowane aplikacje"
New-Item -Path $uninst -Force | Out-Null
$vals = @{
    DisplayName     = 'SebSandbox'
    DisplayVersion  = [string]$cfg.Version
    Publisher       = 'Sebarkh'
    InstallLocation = $root
    UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $root 'Uninstall.ps1')`""
    DisplayIcon     = $icon
}
foreach ($k in $vals.Keys) { Set-ItemProperty -Path $uninst -Name $k -Value $vals[$k] }
Set-ItemProperty -Path $uninst -Name NoModify -Value 1 -Type DWord
Set-ItemProperty -Path $uninst -Name NoRepair -Value 1 -Type DWord
