# Tworzy build\Install-SebSandbox.ps1: szablon + pliki programu z ..\src zakodowane w Base64.
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$src     = Join-Path (Split-Path -Parent $here) 'src'
$version = ([IO.File]::ReadAllText((Join-Path $here 'version.txt'))).Trim()
$files   = 'Start-SebSandbox.ps1', 'Tools\Inside.ps1', 'Register.ps1', 'Uninstall.ps1', 'Clean-Runs.ps1', 'SebSandbox.ico'
$lines = foreach ($f in $files) {
    $p = Join-Path $src $f
    if (-not (Test-Path -LiteralPath $p)) { throw "Brak pliku: $p" }
    "    '$f' = '" + [Convert]::ToBase64String([IO.File]::ReadAllBytes($p)) + "'"
}
$t   = [IO.File]::ReadAllText((Join-Path $here 'Install-SebSandbox.template.ps1'))
$out = $t.Replace('__FILES__', ($lines -join "`r`n")).Replace('__VERSION__', $version)
[IO.File]::WriteAllText((Join-Path $here 'Install-SebSandbox.ps1'), $out, (New-Object System.Text.UTF8Encoding $true))
Write-Host "Install-SebSandbox.ps1 $version - gotowy" -ForegroundColor Green
