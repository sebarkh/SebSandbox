Add-Type -AssemblyName System.Windows.Forms
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$q = [System.Windows.Forms.MessageBox]::Show("Odinstalować SebSandbox?`n`nZostaną usunięte: menu kontekstowe, skróty i wpis w Zainstalowanych aplikacjach.", 'SebSandbox', 'YesNo', 'Question')
if ($q -ne 'Yes') { exit }
& (Join-Path $root 'Register.ps1') -Remove

$q2 = [System.Windows.Forms.MessageBox]::Show("Usunąć też folder programu razem z raportami testów?`n`n$root", 'SebSandbox', 'YesNo', 'Question')
if ($q2 -eq 'Yes') {
    # folder kasuje osobny proces po zamknięciu tego skryptu (skrypt nie usunie folderu, z którego działa)
    Start-Process cmd.exe -ArgumentList "/c timeout /t 2 /nobreak >nul & rmdir /s /q `"$root`"" -WindowStyle Hidden
}
[void][System.Windows.Forms.MessageBox]::Show("SebSandbox odinstalowany.`n`nFunkcja Windows Sandbox zostaje włączona. Można ją wyłączyć w: Włącz lub wyłącz funkcje systemu Windows.", 'SebSandbox', 'OK', 'Information')
