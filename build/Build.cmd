@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Make-Installer.ps1"
if errorlevel 1 goto :end
set /p VER=<"%~dp0version.txt"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "if (-not (Get-Module -ListAvailable ps2exe)) { Install-Module ps2exe -Scope CurrentUser -Force }; Invoke-ps2exe -inputFile '%~dp0Install-SebSandbox.ps1' -outputFile '%~dp0SebSandbox-Setup.exe' -iconFile '%~dp0..\src\SebSandbox.ico' -noConsole -requireAdmin -title 'SebSandbox Setup' -product 'SebSandbox' -company 'Sebarkh' -version '%VER%.0.0'"
rem podpis (opcjonalnie): skrypt Sign.ps1 z wlasnym certyfikatem, jesli istnieje
if exist "E:\SebarkhCert\Sign.ps1" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "E:\SebarkhCert\Sign.ps1" "%~dp0SebSandbox-Setup.exe"
:end
pause
