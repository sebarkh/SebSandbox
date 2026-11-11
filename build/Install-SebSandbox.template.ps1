param([switch]$Silent, [string]$Target)
# SebSandbox - instalator (szablon). Build.cmd -> Make-Installer.ps1 wstawia pliki z ..\src w miejsce __FILES__,
# potem ps2exe kompiluje wynik do SebSandbox-Setup.exe.
# -Silent : instalacja bez okien z domyślnymi opcjami (lub z install.json, jeśli jest w folderze docelowym).
$Version = '__VERSION__'
$Files = @{
__FILES__
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------- sprawdzenia
function Get-Checks {
    $c = [ordered]@{}
    $ed = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
    $c.Edition = @{ Ok = ($ed -notmatch '^Core'); Text = "Wersja Windows: $ed" }
    if (-not $c.Edition.Ok) { $c.Edition.Text += ' - Windows Sandbox wymaga wersji Pro, Enterprise lub Education.' }

    $fw  = (Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled
    $hyp = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
    $c.Virt = @{ Ok = ($fw -or $hyp); Text = 'Wirtualizacja w BIOS/UEFI: ' + $(if ($fw -or $hyp) { 'włączona' } else { 'WYŁĄCZONA' }) }
    if (-not $c.Virt.Ok) {
        $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Manufacturer
        $opt = if ($cpu -match 'AMD') { 'SVM Mode (AMD)' } else { 'Intel Virtualization Technology (VT-x)' }
        $c.Virt.Text += " - włącz w BIOS opcję: $opt. Bez niej piaskownica się nie uruchomi."
    }

    $state = 'nieznany'
    try { $state = [string](Get-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -ErrorAction Stop).State } catch {}
    $c.Feature = @{ Ok = ($state -eq 'Enabled'); State = $state; Text = 'Funkcja Windows Sandbox: ' + $(if ($state -eq 'Enabled') { 'włączona' } else { 'wyłączona - instalator ją włączy (potrzebny restart)' }) }
    $c
}

function Get-DefaultTarget {
    if ($Target) { return $Target }
    $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SebSandbox'
    $loc = (Get-ItemProperty $reg -ErrorAction SilentlyContinue).InstallLocation
    if ($loc) { return $loc }
    if (Test-Path 'E:\Programs') { return 'E:\Programs\SebSandbox' }
    Join-Path $env:LOCALAPPDATA 'Programs\SebSandbox'
}

# ---------------------------------------------------------------- instalacja
function Install-App([string]$Dir, [bool]$Ctx, [bool]$Start, [bool]$Desk, [bool]$Kit, [bool]$EnableFeature, [scriptblock]$Log) {
    $restart = $false
    & $Log "Folder: $Dir"
    New-Item -ItemType Directory -Path $Dir, (Join-Path $Dir 'Tools'), (Join-Path $Dir 'Runs') -Force | Out-Null
    foreach ($rel in $Files.Keys) {
        $dst = Join-Path $Dir $rel
        [IO.File]::WriteAllBytes($dst, [Convert]::FromBase64String($Files[$rel]))
        & $Log "  plik: $rel"
    }
    foreach ($old in 'SebSandbox-menu.reg', 'Wyczysc-testy.cmd') {
        $p = Join-Path $Dir $old
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; & $Log "  usunięty stary plik: $old" }
    }
    @{ ContextMenu = $Ctx; StartMenu = $Start; Desktop = $Desk; Version = $Version } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $Dir 'install.json') -Encoding UTF8

    if ($EnableFeature) {
        & $Log 'Włączanie funkcji Windows Sandbox (może potrwać kilka minut)...'
        try {
            $r = Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All -NoRestart -ErrorAction Stop
            $restart = $true
            & $Log '  włączona - zadziała po restarcie komputera'
        } catch { & $Log "  BŁĄD: $($_.Exception.Message)" }
    }

    if ($Kit) {
        $kd = Join-Path $Dir 'Kit'
        New-Item -ItemType Directory -Path $kd -Force | Out-Null
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        foreach ($t in 'Procmon64.exe', 'Autoruns64.exe') {
            $dst = Join-Path $kd $t
            if (Test-Path -LiteralPath $dst) { & $Log "  Kit: $t już jest"; continue }
            try { Invoke-WebRequest -Uri "https://live.sysinternals.com/$t" -OutFile $dst -UseBasicParsing -ErrorAction Stop; & $Log "  Kit: pobrano $t" }
            catch { & $Log "  Kit: nie udało się pobrać $t ($($_.Exception.Message))" }
        }
    }

    & $Log 'Rejestracja: menu kontekstowe, skróty, wpis w Zainstalowanych aplikacjach...'
    Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Dir 'Register.ps1')`"" -WindowStyle Hidden -Wait
    & $Log 'Gotowe.'
    $restart
}

# ---------------------------------------------------------------- tryb cichy
if ($Silent) {
    $dir = Get-DefaultTarget
    $o = @{ ContextMenu = $true; StartMenu = $true; Desktop = $false }
    try { $j = Get-Content (Join-Path $dir 'install.json') -Raw -ErrorAction Stop | ConvertFrom-Json; foreach ($k in 'ContextMenu', 'StartMenu', 'Desktop') { if ($null -ne $j.$k) { $o[$k] = [bool]$j.$k } } } catch {}
    $chk = Get-Checks
    $logFile = Join-Path $env:TEMP 'SebSandbox-install.log'
    [void](Install-App $dir $o.ContextMenu $o.StartMenu $o.Desktop $true (-not $chk.Feature.Ok) { param($m) Add-Content -LiteralPath $logFile -Value $m -Encoding UTF8 })
    exit 0
}

# ---------------------------------------------------------------- okno instalatora
$chk  = Get-Checks
$font = New-Object System.Drawing.Font('Segoe UI', 9)
$f = New-Object System.Windows.Forms.Form
$f.Text = "SebSandbox $Version - instalator"; $f.Font = $font
try { $f.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch {}
$f.Size = New-Object System.Drawing.Size(640, 600)
$f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false

$hdr = New-Object System.Windows.Forms.Label
$hdr.Text = 'SebSandbox uruchamia programy w Windows Sandbox i pokazuje, co zmieniły w systemie.'
$hdr.Location = '15,12'; $hdr.Size = '600,20'

$gChk = New-Object System.Windows.Forms.GroupBox
$gChk.Text = 'Sprawdzenie systemu'; $gChk.Location = '15,38'; $gChk.Size = '595,118'
$y = 24
foreach ($k in 'Edition', 'Virt', 'Feature') {
    $c = $chk[$k]
    $l = New-Object System.Windows.Forms.Label
    $mark = if ($c.Ok) { [char]0x2714 } elseif ($k -eq 'Feature') { [char]0x2192 } else { [char]0x2716 }
    $l.Text = "$mark  $($c.Text)"
    $l.Location = New-Object System.Drawing.Point(12, $y); $l.Size = '570,30'
    $l.ForeColor = if ($c.Ok) { [System.Drawing.Color]::DarkGreen } elseif ($k -eq 'Feature') { [System.Drawing.Color]::DarkGoldenrod } else { [System.Drawing.Color]::Firebrick }
    $gChk.Controls.Add($l)
    $y += 30
}

$gOpt = New-Object System.Windows.Forms.GroupBox
$gOpt.Text = 'Opcje instalacji'; $gOpt.Location = '15,164'; $gOpt.Size = '595,190'
$lDir = New-Object System.Windows.Forms.Label; $lDir.Text = 'Folder:'; $lDir.Location = '12,28'; $lDir.Size = '50,20'
$tDir = New-Object System.Windows.Forms.TextBox; $tDir.Location = '65,25'; $tDir.Size = '410,24'; $tDir.Text = Get-DefaultTarget
$bDir = New-Object System.Windows.Forms.Button; $bDir.Text = 'Zmień...'; $bDir.Location = '485,23'; $bDir.Size = '95,28'
$cCtx  = New-Object System.Windows.Forms.CheckBox; $cCtx.Text = 'Menu kontekstowe "Uruchom w piaskownicy" (prawy klik na .exe / .msi)'; $cCtx.Location = '12,60'; $cCtx.Size = '570,24'; $cCtx.Checked = $true
$cStart = New-Object System.Windows.Forms.CheckBox; $cStart.Text = 'Skrót w menu Start (okno programu)'; $cStart.Location = '12,86'; $cStart.Size = '570,24'; $cStart.Checked = $true
$cDesk = New-Object System.Windows.Forms.CheckBox; $cDesk.Text = 'Skrót na pulpicie'; $cDesk.Location = '12,112'; $cDesk.Size = '570,24'
$cKit  = New-Object System.Windows.Forms.CheckBox; $cKit.Text = 'Pobierz Process Monitor i Autoruns (Sysinternals) do użycia w piaskownicy'; $cKit.Location = '12,138'; $cKit.Size = '570,24'; $cKit.Checked = $true
$gOpt.Controls.AddRange(@($lDir, $tDir, $bDir, $cCtx, $cStart, $cDesk, $cKit))

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = 'Vertical'
$logBox.Location = '15,362'; $logBox.Size = '595,140'; $logBox.Font = New-Object System.Drawing.Font('Consolas', 9)

$bInst = New-Object System.Windows.Forms.Button; $bInst.Text = 'Zainstaluj'; $bInst.Location = '400,512'; $bInst.Size = '100,32'
$bInst.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$bCancel = New-Object System.Windows.Forms.Button; $bCancel.Text = 'Zamknij'; $bCancel.Location = '510,512'; $bCancel.Size = '100,32'
$f.Controls.AddRange(@($hdr, $gChk, $gOpt, $logBox, $bInst, $bCancel))

if (-not $chk.Edition.Ok) {
    $bInst.Enabled = $false
    $logBox.Text = 'Ta wersja Windows nie ma funkcji Windows Sandbox. Instalacja nie jest możliwa.'
} elseif (-not $chk.Virt.Ok) {
    $logBox.Text = "Wirtualizacja jest wyłączona w BIOS. Możesz zainstalować SebSandbox teraz, ale piaskownica zadziała dopiero po jej włączeniu.`r`n"
}

$LogFn = { param($m) $logBox.AppendText("$m`r`n"); [System.Windows.Forms.Application]::DoEvents() }
$bDir.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Folder instalacji SebSandbox (tam będą też raporty testów)'
    if (Test-Path $tDir.Text) { $d.SelectedPath = $tDir.Text }
    if ($d.ShowDialog($f) -eq 'OK') {
        $p = $d.SelectedPath
        if ((Split-Path $p -Leaf) -ne 'SebSandbox') { $p = Join-Path $p 'SebSandbox' }
        $tDir.Text = $p
    }
})
$bCancel.Add_Click({ $f.Close() })
$bInst.Add_Click({
    if (-not ($cCtx.Checked -or $cStart.Checked -or $cDesk.Checked)) {
        [void][System.Windows.Forms.MessageBox]::Show($f, 'Zaznacz menu kontekstowe albo przynajmniej jeden skrót - inaczej nie będzie jak uruchomić SebSandbox.', 'SebSandbox', 'OK', 'Warning')
        return
    }
    $bInst.Enabled = $false; $gOpt.Enabled = $false; $f.UseWaitCursor = $true
    $restart = $false
    try { $restart = Install-App $tDir.Text $cCtx.Checked $cStart.Checked $cDesk.Checked $cKit.Checked (-not $chk.Feature.Ok) $LogFn }
    catch { & $LogFn "BŁĄD: $($_.Exception.Message)" }
    $f.UseWaitCursor = $false
    $bCancel.Text = 'Zakończ'
    if ($restart) {
        $q = [System.Windows.Forms.MessageBox]::Show($f, "Windows Sandbox zadziała po restarcie komputera.`n`nUruchomić ponownie teraz?", 'SebSandbox', 'YesNo', 'Question')
        if ($q -eq 'Yes') { Restart-Computer -Force }
    } else {
        [void][System.Windows.Forms.MessageBox]::Show($f, 'SebSandbox jest zainstalowany. Uruchomisz go z menu Start albo prawym klikiem na pliku .exe.', 'SebSandbox', 'OK', 'Information')
    }
})
[void]$f.ShowDialog()
