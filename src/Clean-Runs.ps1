Add-Type -AssemblyName System.Windows.Forms
$runs = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Runs'
$dirs = @(Get-ChildItem -LiteralPath $runs -Directory -ErrorAction SilentlyContinue)
if ($dirs.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show('Folder Runs jest pusty.', 'SebSandbox') | Out-Null
    exit
}
$bytes = ($dirs | Get-ChildItem -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
$mb = [math]::Round($bytes / 1MB, 1)
$q = [System.Windows.Forms.MessageBox]::Show("Usunąć $($dirs.Count) folder(y) testów ($mb MB)?`n`n$runs", 'SebSandbox', 'YesNo', 'Question')
if ($q -ne 'Yes') { exit }
$failed = @()
foreach ($d in $dirs) {
    try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop }
    catch { $failed += $d.Name }
}
if ($failed.Count) {
    [System.Windows.Forms.MessageBox]::Show("Nie usunięto (piaskownica jeszcze otwarta?):`n`n$($failed -join "`n")", 'SebSandbox') | Out-Null
} else {
    [System.Windows.Forms.MessageBox]::Show('Wyczyszczono.', 'SebSandbox') | Out-Null
}
