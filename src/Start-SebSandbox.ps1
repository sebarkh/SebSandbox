param([string]$Path)
# SebSandbox - test programów w Windows Sandbox.
#   bez -Path : okno główne (wybór pliku, przeciąganie, ostatnie testy)
#   z -Path   : okno opcji dla wskazanego pliku (menu kontekstowe, przeciągnięcie na skrót)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
Add-Type -Namespace SebSbHost -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
[DllImport("user32.dll")] public static extern bool FlashWindow(IntPtr hWnd, bool bInvert);
'@

$root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$tools    = Join-Path $root 'Tools'
$kit      = Join-Path $root 'Kit'
$runsDir  = Join-Path $root 'Runs'
$settings = Join-Path $root 'settings.json'
$font     = New-Object System.Drawing.Font('Segoe UI', 9)
$appIcon  = $null
try { $appIcon = New-Object System.Drawing.Icon (Join-Path $root 'SebSandbox.ico') } catch {}

function Esc([string]$s) { [System.Security.SecurityElement]::Escape($s) }
function Msg([string]$text, [string]$buttons = 'OK', [string]$icon = 'Information') {
    [System.Windows.Forms.MessageBox]::Show($text, 'SebSandbox', $buttons, $icon)
}
function Get-Opt {
    $o = @{ Internet = $false; Folder = $true; AutoExit = $true; Every = $false; Minutes = 5 }
    try {
        $j = Get-Content -LiteralPath $settings -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($k in 'Internet', 'Folder', 'AutoExit', 'Every') { if ($null -ne $j.$k) { $o[$k] = [bool]$j.$k } }
        if ($j.Minutes) { $o.Minutes = [int]$j.Minutes }
    } catch {}
    $o
}
function Save-Opt($o) {
    try { $o | ConvertTo-Json | Set-Content -LiteralPath $settings -Encoding UTF8 } catch {}
}
# kontrolki "raport automatyczny" (wspólne dla okna opcji i okna głównego)
function Add-AutoControls($parent, [int]$x, [int]$y, $o) {
    $c = @{}
    $c.Exit = New-Object System.Windows.Forms.CheckBox
    $c.Exit.Text = 'Raport automatycznie po zamknięciu testowanego programu'
    $c.Exit.Location = New-Object System.Drawing.Point($x, $y); $c.Exit.Size = '440,24'; $c.Exit.Checked = $o.AutoExit
    $c.Every = New-Object System.Windows.Forms.CheckBox
    $c.Every.Text = 'Raport automatycznie co'
    $c.Every.Location = New-Object System.Drawing.Point($x, ($y + 26)); $c.Every.Size = '170,24'; $c.Every.Checked = $o.Every
    $c.Num = New-Object System.Windows.Forms.NumericUpDown
    $c.Num.Minimum = 1; $c.Num.Maximum = 120; $c.Num.Value = [Math]::Min(120, [Math]::Max(1, $o.Minutes))
    $c.Num.Location = New-Object System.Drawing.Point(($x + 172), ($y + 26)); $c.Num.Size = '55,24'; $c.Num.Enabled = $o.Every
    $c.Lbl = New-Object System.Windows.Forms.Label
    $c.Lbl.Text = 'min (skanowanie może dać krótkie przycięcia)'
    $c.Lbl.Location = New-Object System.Drawing.Point(($x + 232), ($y + 29)); $c.Lbl.AutoSize = $true
    $num = $c.Num
    $c.Every.Add_CheckedChanged({ $num.Enabled = $this.Checked }.GetNewClosure())
    $parent.Controls.AddRange(@($c.Exit, $c.Every, $c.Num, $c.Lbl))
    $c
}
function Test-Runnable([string]$p) {
    $p -and (Test-Path -LiteralPath $p -PathType Leaf) -and ([IO.Path]::GetExtension($p) -in '.exe', '.msi')
}

# ---------------------------------------------------------------- uruchomienie testu
function Start-Run([string]$File, $o) {
    $Internet = [bool]$o.Internet; $WholeFolder = [bool]$o.Folder
    $name = [IO.Path]::GetFileName($File)
    $full = [IO.Path]::GetFullPath($File)
    $appDir = $null; $rel = $null
    if ($WholeFolder) {
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "Wybierz folder, który ma być widoczny w piaskownicy (tylko do odczytu). Musi zawierać $name. Domyślnie: folder pliku."
        $dlg.SelectedPath = Split-Path -Parent $full
        $dlg.ShowNewFolderButton = $false
        while ($true) {
            if ($dlg.ShowDialog($owner) -ne 'OK') { return $null }
            $appDir = $dlg.SelectedPath.TrimEnd('\')
            if (-not $full.StartsWith($appDir + '\', [StringComparison]::OrdinalIgnoreCase)) {
                [void][System.Windows.Forms.MessageBox]::Show($owner, "Wybrany folder nie zawiera pliku:`n$full", 'SebSandbox')
                continue
            }
            $downloads = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
            if ($appDir.Length -le 2 -or $appDir -ieq $downloads.TrimEnd('\')) {
                $q = [System.Windows.Forms.MessageBox]::Show($owner, "Wybrałeś $appDir\ - cały ten folder będzie widoczny w piaskownicy. Kontynuować?", 'SebSandbox', 'YesNo', 'Warning')
                if ($q -ne 'Yes') { continue }
            }
            break
        }
        $rel = $full.Substring($appDir.Length + 1)
        if ($appDir.Length -le 2) { $appDir += '\' }
    }

    $safe = $name -replace '[^\w\.\-]', '_'
    $run  = Join-Path $runsDir ('{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $safe)
    $in   = Join-Path $run 'In'
    $out  = Join-Path $run 'Out'
    New-Item -ItemType Directory -Path $in, $out -Force | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding $true

    # przycisk główny myszy w piaskownicy = jak na tym komputerze (SM_SWAPBUTTON = 23)
    $swap = if ([SebSbHost.Native]::GetSystemMetrics(23) -ne 0) { '1' } else { '0' }
    [IO.File]::WriteAllText((Join-Path $in 'mouse.txt'), $swap, $utf8)
    # raport automatyczny: po zamknięciu programu i/lub co N minut (0 = wyłączone)
    $min = if ($o.Every) { [int]$o.Minutes } else { 0 }
    [IO.File]::WriteAllText((Join-Path $in 'auto.txt'), "exit=$(if ($o.AutoExit) { 1 } else { 0 });minutes=$min", $utf8)

    $extra = ''
    if ($WholeFolder) {
        [IO.File]::WriteAllText((Join-Path $in 'target.txt'), $rel, $utf8)
        $extra += "<MappedFolder><HostFolder>$(Esc $appDir)</HostFolder><SandboxFolder>C:\Test\App</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>"
    } else {
        Copy-Item -LiteralPath $full -Destination (Join-Path $in $safe)
    }
    if (Test-Path -LiteralPath $kit) {
        $extra += "<MappedFolder><HostFolder>$(Esc $kit)</HostFolder><SandboxFolder>C:\Test\Kit</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>"
    }
    $net = if ($Internet) { 'Enable' } else { 'Disable' }
    $wsb = @"
<Configuration>
  <vGPU>Enable</vGPU>
  <MemoryInMB>8192</MemoryInMB>
  <Networking>$net</Networking>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <PrinterRedirection>Disable</PrinterRedirection>
  <MappedFolders>
    <MappedFolder><HostFolder>$(Esc $in)</HostFolder><SandboxFolder>C:\Test\In</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
    <MappedFolder><HostFolder>$(Esc $tools)</HostFolder><SandboxFolder>C:\Test\Tools</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
    <MappedFolder><HostFolder>$(Esc $out)</HostFolder><SandboxFolder>C:\Test\Out</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>
    $extra
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Test\Tools\Inside.ps1</Command>
  </LogonCommand>
</Configuration>
"@
    $wsbPath = Join-Path $run 'test.wsb'
    [IO.File]::WriteAllText($wsbPath, $wsb, (New-Object System.Text.UTF8Encoding $false))
    $mode = if ($Internet) { 'z internetem' } else { 'bez internetu' }
    if ($WholeFolder) { $mode += ', z folderem' }
    [IO.File]::WriteAllText((Join-Path $run 'info.txt'), "$full`r`n$mode", $utf8)

    try { Start-Process -FilePath $wsbPath -ErrorAction Stop }
    catch {
        [void](Msg "Nie udało się uruchomić Windows Sandbox. Sprawdź, czy funkcja jest włączona (instalator SebSandbox to sprawdza).`n`n$($_.Exception.Message)" 'OK' 'Error')
        Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
        return $null
    }
    $run
}

# ---------------------------------------------------------------- okno raportu
function Show-ReportWindow([string]$run, [switch]$Background) {
    $report = Join-Path $run 'Out\raport.txt'
    $info   = @('', '')
    try { $info = [IO.File]::ReadAllLines((Join-Path $run 'info.txt')) } catch {}
    $title  = if ($info[0]) { [IO.Path]::GetFileName($info[0]) } else { Split-Path -Leaf $run }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "SebSandbox - $title $(if ($info[1]) { "($($info[1]))" })"
    $form.Size = New-Object System.Drawing.Size(1100, 750)
    $form.StartPosition = 'CenterScreen'
    $form.Font = $font
    if ($appIcon) { $form.Icon = $appIcon }
    # nowy test: okno raportu startuje zminimalizowane, żeby nie zasłaniać piaskownicy;
    # gdy pojawi się raport, przycisk na pasku zadań zamiga
    if ($Background) { $form.WindowState = 'Minimized'; $form.ShowInTaskbar = $true }

    $status = New-Object System.Windows.Forms.Label
    $status.Dock = 'Top'
    $status.Height = 28
    $status.TextAlign = 'MiddleLeft'
    $status.Text = "  Raport pojawi się tutaj po kliknięciu 'Zrób raport' w piaskownicy."

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true; $box.ReadOnly = $true; $box.ScrollBars = 'Both'; $box.WordWrap = $false; $box.Dock = 'Fill'
    $box.Font = New-Object System.Drawing.Font('Consolas', 9)

    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    $panel.Dock = 'Bottom'; $panel.Height = 42; $panel.FlowDirection = 'RightToLeft'

    $add = {
        param([string]$text, [scriptblock]$action)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text; $b.AutoSize = $true; $b.Add_Click($action)
        $panel.Controls.Add($b) | Out-Null
    }
    & $add 'Zamknij (zostaw folder testu)' { $form.Close() }
    & $add 'Usuń folder testu i zamknij' {
        if (-not (Test-Path -LiteralPath $run)) { $form.Close(); return }
        if ((Msg "Usunąć folder testu?`n$run`n`nNajpierw zamknij okno Windows Sandbox." 'YesNo' 'Question') -ne 'Yes') { return }
        try { Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction Stop } catch {}
        if (Test-Path -LiteralPath $run) { [void](Msg 'Folder testu jest jeszcze używany. Zamknij okno Windows Sandbox i kliknij ponownie.') }
        else { $form.Close() }
    }
    & $add 'Kopiuj zawartość logu' {
        if (-not (Test-Path -LiteralPath $report)) { [void](Msg "Brak raportu. Najpierw kliknij 'Zrób raport' w piaskownicy."); return }
        Set-Clipboard -Value ([IO.File]::ReadAllText($report))
        $status.Text = '  Zawartość raportu skopiowana do schowka.'
    }
    & $add 'Otwórz folder testu' {
        if (Test-Path -LiteralPath $run) { Start-Process explorer.exe -ArgumentList "`"$run`"" }
        else { [void](Msg 'Folder testu został już usunięty.') }
    }

    $state = @{ Last = [datetime]::MinValue }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 2000
    $tick = {
        if (Test-Path -LiteralPath $report) {
            $t = (Get-Item -LiteralPath $report).LastWriteTime
            if ($t -ne $state.Last) {
                try {
                    $box.Text = [IO.File]::ReadAllText($report)
                    $state.Last = $t
                    $status.Text = "  Raport z $($t.ToString('HH:mm:ss')). Kolejny raport możesz zrobić w piaskownicy."
                    if ($form.IsHandleCreated -and $form.WindowState -eq 'Minimized') { [void][SebSbHost.Native]::FlashWindow($form.Handle, $true) }
                } catch {}
            }
        }
    }
    $timer.Add_Tick($tick)
    $timer.Start()
    & $tick

    $form.Controls.Add($box); $form.Controls.Add($panel); $form.Controls.Add($status)
    $form.Add_FormClosed({ $timer.Stop() })
    [void]$form.ShowDialog()
}

# ---------------------------------------------------------------- tryb: plik wskazany (menu kontekstowe)
if ($Path) {
    if (-not (Test-Runnable $Path)) { [void](Msg "To nie jest plik .exe ani .msi:`n$Path" 'OK' 'Warning'); exit }
    $opt = Get-Opt
    $of = New-Object System.Windows.Forms.Form
    $of.Text = 'SebSandbox'; $of.Font = $font
    if ($appIcon) { $of.Icon = $appIcon }
    $of.Size = New-Object System.Drawing.Size(560, 285)
    $of.StartPosition = 'CenterScreen'; $of.FormBorderStyle = 'FixedDialog'; $of.MaximizeBox = $false; $of.MinimizeBox = $false; $of.TopMost = $true

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Plik: $([IO.Path]::GetFileName($Path))"; $lbl.Location = '15,15'; $lbl.Size = '430,20'
    $cbNet = New-Object System.Windows.Forms.CheckBox
    $cbNet.Text = 'Internet (program może łączyć się z siecią)'; $cbNet.Location = '15,45'; $cbNet.Size = '430,24'; $cbNet.Checked = $opt.Internet
    $cbFolder = New-Object System.Windows.Forms.CheckBox
    $cbFolder.Text = 'Podłącz folder programu (wybierzesz który, tylko do odczytu)'; $cbFolder.Location = '15,72'; $cbFolder.Size = '430,24'; $cbFolder.Checked = $opt.Folder

    $bRun = New-Object System.Windows.Forms.Button
    $auto = Add-AutoControls $of 15 102 $opt
    $bRun.Text = 'Uruchom'; $bRun.Location = '15,195'; $bRun.Size = '110,30'; $bRun.DialogResult = 'OK'
    $bClean = New-Object System.Windows.Forms.Button
    $bClean.Text = 'Wyczyść stare testy'; $bClean.Location = '135,195'; $bClean.Size = '160,30'
    $bClean.Add_Click({ & (Join-Path $root 'Clean-Runs.ps1') })
    $bCancel = New-Object System.Windows.Forms.Button
    $bCancel.Text = 'Anuluj'; $bCancel.Location = '425,195'; $bCancel.Size = '100,30'; $bCancel.DialogResult = 'Cancel'

    $of.Controls.AddRange(@($lbl, $cbNet, $cbFolder, $bRun, $bClean, $bCancel))
    $of.AcceptButton = $bRun; $of.CancelButton = $bCancel
    if ($of.ShowDialog() -ne 'OK') { exit }
    $o = @{ Internet = $cbNet.Checked; Folder = $cbFolder.Checked; AutoExit = $auto.Exit.Checked; Every = $auto.Every.Checked; Minutes = [int]$auto.Num.Value }
    Save-Opt $o
    $run = Start-Run $Path $o
    if ($run) { Show-ReportWindow $run -Background }
    exit
}

# ---------------------------------------------------------------- tryb: okno główne
$opt = Get-Opt
$mf = New-Object System.Windows.Forms.Form
$mf.Text = 'SebSandbox'; $mf.Font = $font
if ($appIcon) { $mf.Icon = $appIcon }
$mf.Size = New-Object System.Drawing.Size(860, 620)
$mf.MinimumSize = New-Object System.Drawing.Size(640, 460)
$mf.StartPosition = 'CenterScreen'
$mf.AllowDrop = $true

$grp = New-Object System.Windows.Forms.GroupBox
$grp.Text = 'Nowy test'; $grp.Dock = 'Top'; $grp.Height = 220; $grp.Padding = '10,8,10,8'

$tbFile = New-Object System.Windows.Forms.TextBox
$tbFile.Location = '15,28'; $tbFile.Size = '560,24'; $tbFile.Anchor = 'Top,Left,Right'
$tbFile.Text = 'Przeciągnij tu plik .exe / .msi albo kliknij "Wybierz plik..."'
$tbFile.ForeColor = [System.Drawing.Color]::Gray; $tbFile.ReadOnly = $true
$bPick = New-Object System.Windows.Forms.Button
$bPick.Text = 'Wybierz plik...'; $bPick.Location = '585,26'; $bPick.Size = '130,28'; $bPick.Anchor = 'Top,Right'

$cbNet2 = New-Object System.Windows.Forms.CheckBox
$cbNet2.Text = 'Internet (program może łączyć się z siecią)'; $cbNet2.Location = '15,62'; $cbNet2.Size = '500,24'; $cbNet2.Checked = $opt.Internet
$cbFolder2 = New-Object System.Windows.Forms.CheckBox
$cbFolder2.Text = 'Podłącz folder programu (wybierzesz który, tylko do odczytu)'; $cbFolder2.Location = '15,88'; $cbFolder2.Size = '500,24'; $cbFolder2.Checked = $opt.Folder

$bGo = New-Object System.Windows.Forms.Button
$bGo.Text = 'Uruchom w piaskownicy'; $bGo.Location = '15,175'; $bGo.Size = '200,32'; $bGo.Enabled = $false
$bGo.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$grp.Controls.AddRange(@($tbFile, $bPick, $cbNet2, $cbFolder2, $bGo))
$auto2 = Add-AutoControls $grp 15 116 $opt

$lblRuns = New-Object System.Windows.Forms.Label
$lblRuns.Text = '  Ostatnie testy (dwuklik = raport)'; $lblRuns.Dock = 'Top'; $lblRuns.Height = 26; $lblRuns.TextAlign = 'BottomLeft'

$lv = New-Object System.Windows.Forms.ListView
$lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.Dock = 'Fill'; $lv.HideSelection = $false
[void]$lv.Columns.Add('Data', 140); [void]$lv.Columns.Add('Plik', 260); [void]$lv.Columns.Add('Tryb', 190); [void]$lv.Columns.Add('Raport', 70)

$bp = New-Object System.Windows.Forms.FlowLayoutPanel
$bp.Dock = 'Bottom'; $bp.Height = 44; $bp.FlowDirection = 'RightToLeft'; $bp.Padding = '5,5,5,5'
$bClose = New-Object System.Windows.Forms.Button; $bClose.Text = 'Zamknij'; $bClose.AutoSize = $true
$bCleanAll = New-Object System.Windows.Forms.Button; $bCleanAll.Text = 'Wyczyść stare testy'; $bCleanAll.AutoSize = $true
$bDel = New-Object System.Windows.Forms.Button; $bDel.Text = 'Usuń zaznaczony'; $bDel.AutoSize = $true
$bOpenDir = New-Object System.Windows.Forms.Button; $bOpenDir.Text = 'Otwórz folder'; $bOpenDir.AutoSize = $true
$bShow = New-Object System.Windows.Forms.Button; $bShow.Text = 'Pokaż raport'; $bShow.AutoSize = $true
$bp.Controls.AddRange(@($bClose, $bCleanAll, $bDel, $bOpenDir, $bShow))

$mf.Controls.Add($lv); $mf.Controls.Add($lblRuns); $mf.Controls.Add($bp); $mf.Controls.Add($grp)

$sel = @{ File = $null }
function Set-File([string]$p) {
    if (-not (Test-Runnable $p)) { [void](Msg "To nie jest plik .exe ani .msi:`n$p" 'OK' 'Warning'); return }
    $sel.File = $p
    $tbFile.Text = $p; $tbFile.ForeColor = [System.Drawing.SystemColors]::WindowText
    $bGo.Enabled = $true
}
function Update-Runs {
    $lv.Items.Clear()
    if (-not (Test-Path -LiteralPath $runsDir)) { return }
    foreach ($d in (Get-ChildItem -LiteralPath $runsDir -Directory | Sort-Object Name -Descending)) {
        $date = ''
        if ($d.Name -match '^(\d{8}_\d{6})_') { try { $date = [datetime]::ParseExact($Matches[1], 'yyyyMMdd_HHmmss', $null).ToString('yyyy-MM-dd HH:mm') } catch {} }
        $info = @('', '')
        try { $info = [IO.File]::ReadAllLines((Join-Path $d.FullName 'info.txt')) } catch {}
        $file = if ($info[0]) { [IO.Path]::GetFileName($info[0]) } else { $d.Name -replace '^\d{8}_\d{6}_', '' }
        $has  = if (Test-Path -LiteralPath (Join-Path $d.FullName 'Out\raport.txt')) { 'tak' } else { 'nie' }
        $it = New-Object System.Windows.Forms.ListViewItem($date)
        [void]$it.SubItems.Add($file); [void]$it.SubItems.Add([string]$info[1]); [void]$it.SubItems.Add($has)
        $it.Tag = $d.FullName
        [void]$lv.Items.Add($it)
    }
}
function Get-SelRun { if ($lv.SelectedItems.Count) { $lv.SelectedItems[0].Tag } else { $null } }

$bPick.Add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'Programy (*.exe;*.msi)|*.exe;*.msi'
    $d.Title = 'Wybierz program do testu'
    if ($d.ShowDialog($mf) -eq 'OK') { Set-File $d.FileName }
})
$mf.Add_DragEnter({ param($s, $e) if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $e.Effect = 'Copy' } })
$mf.Add_DragDrop({ param($s, $e) $f = $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop); if ($f) { Set-File $f[0] } })
$bGo.Add_Click({
    if (-not $sel.File) { return }
    $o = @{ Internet = $cbNet2.Checked; Folder = $cbFolder2.Checked; AutoExit = $auto2.Exit.Checked; Every = $auto2.Every.Checked; Minutes = [int]$auto2.Num.Value }
    Save-Opt $o
    $r = Start-Run $sel.File $o
    Update-Runs
    if ($r) {
        $mf.WindowState = 'Minimized'
        Show-ReportWindow $r -Background
        $mf.WindowState = 'Normal'; $mf.Activate()
        Update-Runs
    }
})
$bShow.Add_Click({ $r = Get-SelRun; if ($r) { Show-ReportWindow $r; Update-Runs } })
$lv.Add_DoubleClick({ $r = Get-SelRun; if ($r) { Show-ReportWindow $r; Update-Runs } })
$bOpenDir.Add_Click({ $r = Get-SelRun; if ($r -and (Test-Path -LiteralPath $r)) { Start-Process explorer.exe -ArgumentList "`"$r`"" } })
$bDel.Add_Click({
    $r = Get-SelRun
    if (-not $r) { return }
    if ((Msg "Usunąć ten test?`n$r" 'YesNo' 'Question') -ne 'Yes') { return }
    try { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction Stop } catch {}
    if (Test-Path -LiteralPath $r) { [void](Msg 'Folder testu jest jeszcze używany. Zamknij okno Windows Sandbox i spróbuj ponownie.') }
    Update-Runs
})
$bCleanAll.Add_Click({ & (Join-Path $root 'Clean-Runs.ps1'); Update-Runs })
$bClose.Add_Click({ $mf.Close() })

Update-Runs
[void]$mf.ShowDialog()
