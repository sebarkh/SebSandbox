Add-Type -Namespace SebSb -Name Mouse -MemberDefinition '[DllImport("user32.dll")] public static extern bool SwapMouseButton(bool fSwap);'
# przycisk główny myszy jak na komputerze, z którego uruchomiono test (C:\Test\In\mouse.txt: 1 = zamienione)
$swap = $true
if (Test-Path -LiteralPath 'C:\Test\In\mouse.txt') { $swap = ([IO.File]::ReadAllText('C:\Test\In\mouse.txt').Trim() -eq '1') }
[void][SebSb.Mouse]::SwapMouseButton($swap)
Set-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name SwapMouseButtons -Value $(if ($swap) { '1' } else { '0' }) -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$inDir  = 'C:\Test\In'
$outDir = 'C:\Test\Out'
$kitDir = 'C:\Test\Kit'
$work   = 'C:\TestRun'
$report = Join-Path $outDir 'raport.txt'

# ---------- Monitoring: process creation (with command line), network attempts, DNS ----------
$auditInfo = @()
& auditpol.exe /set /subcategory:'{0CCE922B-69AE-11D9-BED3-505054503030}' /success:enable | Out-Null
if ($LASTEXITCODE -ne 0) { $auditInfo += 'Nie udało się włączyć rejestrowania procesów.' }
& auditpol.exe /set /subcategory:'{0CCE9226-69AE-11D9-BED3-505054503030}' /success:enable /failure:enable | Out-Null
if ($LASTEXITCODE -ne 0) { $auditInfo += 'Nie udało się włączyć rejestrowania połączeń.' }
$auditKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit'
New-Item -Path $auditKey -Force -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty -Path $auditKey -Name ProcessCreationIncludeCmdLine_Enabled -Value 1 -Type DWord -ErrorAction SilentlyContinue
& wevtutil.exe sl 'Microsoft-Windows-DNS-Client/Operational' /e:true | Out-Null
& wevtutil.exe sl Security /ms:268435456 | Out-Null

# ---------- Sysinternals kit ----------
foreach ($t in 'Process Monitor', 'Autoruns') {
    $k = "HKCU:\Software\Sysinternals\$t"
    New-Item -Path $k -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $k -Name EulaAccepted -Value 1 -Type DWord -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath $kitDir) {
    $ws   = New-Object -ComObject WScript.Shell
    $desk = [Environment]::GetFolderPath('Desktop')
    foreach ($f in (Get-ChildItem -LiteralPath $kitDir -Filter *.exe -ErrorAction SilentlyContinue)) {
        $l = $ws.CreateShortcut((Join-Path $desk ($f.BaseName + '.lnk')))
        $l.TargetPath = $f.FullName
        $l.Save()
    }
}

# ---------- Target ----------
$targetFile = Join-Path $inDir 'target.txt'
$appMode = Test-Path -LiteralPath $targetFile
if ($appMode) {
    $rel     = ([IO.File]::ReadAllText($targetFile)).Trim()
    $exe     = Join-Path 'C:\Test\App' $rel
    $srcName = Split-Path -Leaf $exe
    $work    = Split-Path -Parent $exe
} else {
    $src = Get-ChildItem -LiteralPath $inDir -File | Where-Object { $_.Name -notin 'mouse.txt', 'target.txt', 'auto.txt' } | Select-Object -First 1
    $srcName = $src.Name
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    Copy-Item -LiteralPath $src.FullName -Destination $work -Force
    $exe = Join-Path $work $srcName
}

# ---------- Snapshots ----------
$fileRoots = @(
    @{ P = 'C:\Program Files';            R = $true  },
    @{ P = 'C:\Program Files (x86)';      R = $true  },
    @{ P = 'C:\ProgramData';              R = $true  },
    @{ P = $env:USERPROFILE;              R = $true  },
    @{ P = 'C:\Windows\Temp';             R = $true  },
    @{ P = 'C:\Windows\System32\Tasks';   R = $true  },
    @{ P = 'C:\Windows\System32\drivers'; R = $true  },
    @{ P = 'C:\Windows\System32';         R = $false },
    @{ P = 'C:\Windows\SysWOW64';         R = $false },
    @{ P = 'C:\Windows';                  R = $false },
    @{ P = 'C:\';                         R = $false }
)
if (-not $appMode) { $fileRoots += @{ P = $work; R = $true } }
$noise = 'AppData\\Local\\Microsoft\\Windows\\(Explorer|Caches|INetCache|WebCache|PowerShell)|AppData\\Local\\Packages\\|\\ProgramData\\Microsoft\\(Windows Defender|Diagnosis|Windows\\WER)|__PSScriptPolicyTest|\\NTUSER\.DAT|\\UsrClass\.dat|\.etl$'

function Get-FileSnap {
    $h = @{}
    foreach ($r in $fileRoots) {
        if (-not (Test-Path -LiteralPath $r.P)) { continue }
        if ($r.R) { $items = Get-ChildItem -LiteralPath $r.P -File -Force -Recurse -ErrorAction SilentlyContinue }
        else      { $items = Get-ChildItem -LiteralPath $r.P -File -Force -ErrorAction SilentlyContinue }
        foreach ($f in $items) {
            if ($f.FullName -match $noise) { continue }
            $h[$f.FullName] = "$($f.Length) B|$($f.LastWriteTimeUtc.Ticks)"
        }
    }
    $h
}
function Add-Values($h, [string]$path) {
    $k = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if (-not $k) { return }
    foreach ($n in $k.GetValueNames()) { $h["$path :: $n"] = [string]$k.GetValue($n) }
}
function Add-Subkeys($h, [string]$path, [string]$valueName) {
    foreach ($s in (Get-ChildItem -LiteralPath $path -ErrorAction SilentlyContinue)) {
        $v = ''
        if ($valueName) { $v = [string]$s.GetValue($valueName) }
        $h[$s.Name] = $v
    }
}
function Get-RegSnap {
    $h  = @{}
    $cv = 'Microsoft\Windows\CurrentVersion'
    foreach ($p in @(
        "HKLM:\SOFTWARE\$cv\Run", "HKLM:\SOFTWARE\$cv\RunOnce",
        "HKLM:\SOFTWARE\WOW6432Node\$cv\Run", "HKLM:\SOFTWARE\WOW6432Node\$cv\RunOnce",
        "HKCU:\Software\$cv\Run", "HKCU:\Software\$cv\RunOnce",
        "HKLM:\SOFTWARE\$cv\Policies\Explorer\Run", "HKCU:\Software\$cv\Policies\Explorer\Run",
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon',
        'HKLM:\SOFTWARE\Microsoft\Windows Defender\Exclusions\Paths',
        'HKLM:\SOFTWARE\Microsoft\Windows Defender\Exclusions\Processes',
        'HKLM:\SOFTWARE\Microsoft\Windows Defender\Exclusions\Extensions'
    )) { Add-Values $h $p }
    Add-Subkeys $h 'HKLM:\SYSTEM\CurrentControlSet\Services' 'ImagePath'
    Add-Subkeys $h "HKLM:\SOFTWARE\$cv\Uninstall" 'DisplayName'
    Add-Subkeys $h "HKLM:\SOFTWARE\WOW6432Node\$cv\Uninstall" 'DisplayName'
    Add-Subkeys $h "HKCU:\Software\$cv\Uninstall" 'DisplayName'
    Add-Subkeys $h 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' 'Debugger'
    Add-Subkeys $h 'HKLM:\SOFTWARE' ''
    Add-Subkeys $h 'HKLM:\SOFTWARE\WOW6432Node' ''
    Add-Subkeys $h 'HKCU:\Software' ''
    $h
}
function Get-TaskSnap {
    $h = @{}
    foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $h["$($t.TaskPath)$($t.TaskName)"] = (($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join '; ')
    }
    $h
}
function Compare-Snap($old, $new) {
    $a = New-Object System.Collections.Generic.List[string]
    $c = New-Object System.Collections.Generic.List[string]
    $d = New-Object System.Collections.Generic.List[string]
    foreach ($k in $new.Keys) {
        if (-not $old.ContainsKey($k)) { $a.Add($k) }
        elseif ($old[$k] -ne $new[$k]) { $c.Add($k) }
    }
    foreach ($k in $old.Keys) { if (-not $new.ContainsKey($k)) { $d.Add($k) } }
    @{ Added = $a; Changed = $c; Removed = $d }
}

# ---------- Event log readers ----------
function ConvertTo-Pid($v) {
    if ($v -is [string]) { return [Convert]::ToInt64($v, 16) }
    [int64]$v
}
function Get-ProcEvents {
    $out = @()
    try { $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4688; StartTime = $script:testStart } -ErrorAction Stop }
    catch { return @() }
    foreach ($e in $ev) {
        $p = $e.Properties
        $out += [pscustomobject]@{
            Time      = $e.TimeCreated
            Pid       = ConvertTo-Pid $p[4].Value
            ParentPid = ConvertTo-Pid $p[7].Value
            Name      = [string]$p[5].Value
            Cmd       = [string]$p[8].Value
        }
    }
    $out | Sort-Object Time
}
function Get-NetEvents {
    $out = @()
    try { $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 5156, 5157; StartTime = $script:testStart } -ErrorAction Stop }
    catch { return @() }
    foreach ($e in $ev) {
        $p = $e.Properties
        if ([string]$p[2].Value -notmatch '14593') { continue }
        $dst = [string]$p[5].Value
        if ($dst -match '^(127\.|::1$|0\.0\.0\.0$|::$|fe80|ff0|224\.|239\.|255\.)') { continue }
        $proto = switch ([string]$p[7].Value) { '6' { 'TCP' } '17' { 'UDP' } default { [string]$p[7].Value } }
        $out += [pscustomobject]@{
            Time    = $e.TimeCreated
            Pid     = ConvertTo-Pid $p[0].Value
            App     = Split-Path -Leaf ([string]$p[1].Value)
            Dst     = $dst
            Port    = [string]$p[6].Value
            Proto   = $proto
            Blocked = ($e.Id -eq 5157)
        }
    }
    $out
}
function Get-DnsEvents {
    $out = @()
    try { $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-DNS-Client/Operational'; Id = 3006; StartTime = $script:testStart } -ErrorAction Stop }
    catch { return @() }
    foreach ($e in $ev) {
        $out += [pscustomobject]@{ Time = $e.TimeCreated; Pid = [int64]$e.ProcessId; Name = [string]$e.Properties[0].Value }
    }
    $out
}

# ---------- Report ----------
$lolbins  = '^(cmd|powershell|pwsh|wscript|cscript|mshta|rundll32|regsvr32|schtasks|reg|bitsadmin|certutil|curl|wget|vssadmin|wmic|sc|netsh|bcdedit|wevtutil|icacls|takeown|attrib|msiexec|installutil|regasm|regsvcs)\.exe$'
$susExt   = '\.(exe|dll|sys|scr|com|bat|cmd|ps1|vbs|vbe|js|jse|wsf|hta|lnk|msi)$'
$susDir   = '\\AppData\\|\\Temp\\|\\ProgramData\\|^C:\\Windows\\|^C:\\[^\\]+$'

function Add-Section($L, [string]$title, $keys, $values, [switch]$FileMode) {
    $L.Add("=== $title ($($keys.Count)) ===")
    foreach ($k in ($keys | Sort-Object)) {
        $v = $null
        if ($values -and $values.ContainsKey($k)) { $v = $values[$k] }
        if ($FileMode -and $v) { $v = ($v -split '\|')[0] }
        if ($v) { $L.Add("  $k   =>   $v") } else { $L.Add("  $k") }
    }
    $L.Add('')
}

function Write-Report {
    $status.Text = 'Tworzę raport...'
    $form.Refresh()

    $nf = Get-FileSnap;  $f = Compare-Snap $script:baseFiles $nf
    $nr = Get-RegSnap;   $r = Compare-Snap $script:baseReg $nr
    $nt = Get-TaskSnap;  $t = Compare-Snap $script:baseTasks $nt
    $procs = @(Get-ProcEvents)
    $nets  = @(Get-NetEvents)
    $dns   = @(Get-DnsEvents)

    # process tree of the tested program
    $tree = New-Object 'System.Collections.Generic.HashSet[int64]'
    foreach ($p in $script:rootPids) { [void]$tree.Add([int64]$p) }
    foreach ($p in $procs) { if ($tree.Contains($p.ParentPid)) { [void]$tree.Add($p.Pid) } }
    $pidName = @{}
    foreach ($p in $procs) { $pidName[$p.Pid] = Split-Path -Leaf $p.Name }
    foreach ($p in Get-Process) { if (-not $pidName.ContainsKey([int64]$p.Id)) { $pidName[[int64]$p.Id] = "$($p.Name).exe" } }

    # suspicious
    $S = New-Object System.Collections.Generic.List[string]
    foreach ($k in (@($f.Added) + @($f.Changed) | Sort-Object)) {
        if ($k -match '\\Start Menu\\Programs\\Startup\\' -or $k -match 'drivers\\etc\\hosts$' -or ($k -match $susExt -and $k -match $susDir)) { $S.Add("PLIK      $k") }
    }
    foreach ($k in (@($r.Added) + @($r.Changed) | Sort-Object)) {
        if ($k -match '\\Run(Once)? ::|Winlogon|Windows Defender\\Exclusions') { $S.Add("REJESTR   $k   =>   $($nr[$k])") }
        elseif ($k -match '\\Services\\' -and $r.Added.Contains($k)) { $S.Add("USŁUGA    $k   =>   $($nr[$k])") }
        elseif ($k -match 'Image File Execution Options' -and $nr[$k]) { $S.Add("IFEO      $k   =>   $($nr[$k])") }
    }
    foreach ($k in (@($t.Added) + @($t.Changed) | Sort-Object)) { $S.Add("ZADANIE   $k   =>   $($nt[$k])") }
    foreach ($p in $procs) {
        if ($tree.Contains($p.Pid) -and (Split-Path -Leaf $p.Name) -match $lolbins) { $S.Add("PROCES    $($p.Cmd)") }
    }
    foreach ($g in ($dns | Where-Object { $tree.Contains($_.Pid) } | Group-Object Name)) { $S.Add("DNS       $($g.Name)   (zapytań: $($g.Count))") }
    foreach ($g in ($nets | Where-Object { $tree.Contains($_.Pid) } | Group-Object { "$($_.Proto) $($_.Dst):$($_.Port)" })) {
        $bl = if ($g.Group[0].Blocked) { ' [zablokowane]' } else { '' }
        $S.Add("SIEĆ      $($g.Group[0].App) -> $($g.Name)   (prób: $($g.Count))$bl")
    }

    $L = New-Object System.Collections.Generic.List[string]
    $L.Add("RAPORT SebSandbox - $srcName - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $L.Add("Start testu: $($script:testStart.ToString('HH:mm:ss'))   (* = testowany program lub proces przez niego uruchomiony)")
    foreach ($a in $auditInfo) { $L.Add("UWAGA: $a") }
    $L.Add('')
    $L.Add("=== PODEJRZANE - DO SPRAWDZENIA ($($S.Count)) ===")
    if ($S.Count -eq 0) { $L.Add('  brak') } else { foreach ($s in $S) { $L.Add("  $s") } }
    $L.Add('')

    $L.Add("=== WSZYSTKIE PROCESY URUCHOMIONE W CZASIE TESTU ($($procs.Count)) ===")
    foreach ($p in $procs) {
        $m = if ($tree.Contains($p.Pid)) { '*' } else { ' ' }
        $c = if ($p.Cmd) { $p.Cmd } else { $p.Name }
        $L.Add(('{0} {1}  [{2}<-{3}]  {4}' -f $m, $p.Time.ToString('HH:mm:ss'), $p.Pid, $p.ParentPid, $c))
    }
    $L.Add('')

    $L.Add("=== ZAPYTANIA DNS - PRÓBY ODNALEZIENIA SERWERÓW ($($dns.Count)) ===")
    foreach ($g in ($dns | Group-Object { "$($_.Pid)|$($_.Name)" })) {
        $d = $g.Group[0]
        $m = if ($tree.Contains($d.Pid)) { '*' } else { ' ' }
        $L.Add(('{0} {1}  {2,-40}  {3} [{4}]  x{5}' -f $m, $d.Time.ToString('HH:mm:ss'), $d.Name, $pidName[$d.Pid], $d.Pid, $g.Count))
    }
    $L.Add('')

    $L.Add("=== PRÓBY POŁĄCZEŃ WYCHODZĄCYCH ($($nets.Count)) ===")
    foreach ($g in ($nets | Group-Object { "$($_.Pid)|$($_.Proto)|$($_.Dst)|$($_.Port)" })) {
        $n = $g.Group[0]
        $m = if ($tree.Contains($n.Pid)) { '*' } else { ' ' }
        $bl = if ($n.Blocked) { ' [zablokowane]' } else { '' }
        $L.Add(('{0} {1}  {2} {3}:{4}  {5} [{6}]  x{7}{8}' -f $m, $n.Time.ToString('HH:mm:ss'), $n.Proto, $n.Dst, $n.Port, $n.App, $n.Pid, $g.Count, $bl))
    }
    $L.Add('')

    Add-Section $L 'PLIKI NOWE' $f.Added $nf -FileMode
    Add-Section $L 'PLIKI ZMIENIONE' $f.Changed $nf -FileMode
    Add-Section $L 'PLIKI USUNIĘTE' $f.Removed $null
    Add-Section $L 'REJESTR NOWE (autostart, usługi, odinstalowanie, klucze programów, wyjątki Defendera)' $r.Added $nr
    Add-Section $L 'REJESTR ZMIENIONE' $r.Changed $nr
    Add-Section $L 'REJESTR USUNIĘTE' $r.Removed $null
    Add-Section $L 'ZADANIA HARMONOGRAMU NOWE' $t.Added $nt
    Add-Section $L 'ZADANIA HARMONOGRAMU ZMIENIONE' $t.Changed $nt

    [IO.File]::WriteAllLines($report, $L, (New-Object System.Text.UTF8Encoding $true))
    $status.Text = "Raport zapisany $(Get-Date -Format 'HH:mm:ss'). Widać go w oknie na Twoim PC."
}

function Start-Target {
    try {
        if ($exe -like '*.msi') { $p = Start-Process msiexec.exe -ArgumentList "/i `"$exe`"" -WorkingDirectory $work -PassThru -ErrorAction Stop }
        else { $p = Start-Process -FilePath $exe -WorkingDirectory $work -PassThru -ErrorAction Stop }
        $script:rootPids += $p.Id
        $script:autoDone = $false
        $script:idleTicks = 0
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Nie udało się uruchomić programu.`n`n$($_.Exception.Message)", 'SebSandbox') | Out-Null
    }
}

# ---------- Automatyczny raport po zamknięciu testowanego programu ----------
# co 5 s: czy żyje jeszcze testowany program albo którykolwiek proces przez niego uruchomiony
# (drzewo procesów z dziennika zdarzeń 4688, więc liczą się też procesy potomne po zamknięciu launchera)
function Test-TargetAlive {
    $tree = New-Object 'System.Collections.Generic.HashSet[int64]'
    foreach ($p in $script:rootPids) { [void]$tree.Add([int64]$p) }
    foreach ($p in @(Get-ProcEvents)) { if ($tree.Contains($p.ParentPid)) { [void]$tree.Add($p.Pid) } }
    $alive = Get-Process | Where-Object { $tree.Contains([int64]$_.Id) -and $_.StartTime -ge $script:testStart.AddSeconds(-5) }
    [bool]$alive
}
# ustawienia z okna SebSandbox (C:\Test\In\auto.txt): exit=1;minutes=5
$autoExit = $true; $autoMinutes = 0
if (Test-Path -LiteralPath 'C:\Test\In\auto.txt') {
    $a = [IO.File]::ReadAllText('C:\Test\In\auto.txt')
    if ($a -match 'exit=(\d)')     { $autoExit = ($Matches[1] -eq '1') }
    if ($a -match 'minutes=(\d+)') { $autoMinutes = [int]$Matches[1] }
}
$script:autoDone  = $true
$script:idleTicks = 0
$watch = New-Object System.Windows.Forms.Timer
$watch.Interval = 5000
$watch.Add_Tick({
    if ($script:autoDone -or -not $script:rootPids) { return }
    if (Test-TargetAlive) { $script:idleTicks = 0; return }
    $script:idleTicks++
    if ($script:idleTicks -lt 2) { return }
    $script:autoDone = $true
    $watch.Stop()
    Write-Report
    $status.Text = "Program zakończony - raport zrobiony automatycznie ($(Get-Date -Format 'HH:mm:ss')).`nMożesz zamknąć piaskownicę albo uruchomić program ponownie."
    $watch.Start()
})
$periodic = New-Object System.Windows.Forms.Timer
if ($autoMinutes -gt 0) { $periodic.Interval = $autoMinutes * 60000 }
$periodic.Add_Tick({
    $periodic.Stop()
    Write-Report
    $status.Text = "Raport okresowy (co $autoMinutes min) zrobiony $(Get-Date -Format 'HH:mm:ss')."
    $periodic.Start()
})

# ---------- Window ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "SebSandbox - $srcName"
$form.Size = New-Object System.Drawing.Size(480, 170)
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(20, 20)
$form.TopMost = $true

$status = New-Object System.Windows.Forms.Label
$status.Dock = 'Fill'
$status.TextAlign = 'MiddleCenter'
$status.Text = 'Robię zdjęcie systemu przed uruchomieniem programu...'

$panel = New-Object System.Windows.Forms.FlowLayoutPanel
$panel.Dock = 'Bottom'
$panel.Height = 42
$panel.FlowDirection = 'RightToLeft'
$panel.Enabled = $false

$b1 = New-Object System.Windows.Forms.Button
$b1.Text = 'Zrób raport'
$b1.AutoSize = $true
$b1.Add_Click({ Write-Report })
$b2 = New-Object System.Windows.Forms.Button
$b2.Text = 'Uruchom program ponownie'
$b2.AutoSize = $true
$b2.Add_Click({ Start-Target })
$panel.Controls.Add($b1) | Out-Null
$panel.Controls.Add($b2) | Out-Null

$form.Controls.Add($status)
$form.Controls.Add($panel)

$form.Add_Shown({
    $form.Refresh()
    $script:baseFiles = Get-FileSnap
    $script:baseReg   = Get-RegSnap
    $script:baseTasks = Get-TaskSnap
    $script:rootPids  = @()
    $script:testStart = Get-Date
    Start-Target
    $auto = @()
    if ($autoExit) { $auto += 'po zamknięciu programu' }
    if ($autoMinutes -gt 0) { $auto += "co $autoMinutes min" }
    $autoTxt = if ($auto) { 'Raport automatyczny: ' + ($auto -join ' i ') + '.' } else { "Raport automatyczny wyłączony - kliknij 'Zrób raport'." }
    $status.Text = "Program uruchomiony. $autoTxt`nZamknięcie piaskownicy usuwa całe środowisko."
    $panel.Enabled = $true
    if ($autoExit) { $watch.Start() }
    if ($autoMinutes -gt 0) { $periodic.Start() }
})
[void]$form.ShowDialog()
