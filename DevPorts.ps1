# Dev Ports - see what's listening, grouped by project, and stop it cleanly.
param([switch]$Smoke)

$ErrorActionPreference = 'Stop'

try {
    Add-Type -TypeDefinition @'
public class PortApp {
    public string App { get; set; }
    public string Ports { get; set; }
    public string Process { get; set; }
    public string Folder { get; set; }
    public string Uptime { get; set; }
    public string Mem { get; set; }
    public string Kind { get; set; }
    public string Cmd { get; set; }
    public int KillPid { get; set; }
    public string DockerName { get; set; }
    public int FirstPort { get; set; }
    public int SortKey { get; set; }
}
'@
} catch { } # type already loaded on re-run

$SystemNames = @('system','idle','svchost.exe','lsass.exe','services.exe','wininit.exe',
    'winlogon.exe','csrss.exe','spoolsv.exe','dns.exe','searchhost.exe','memory compression')
$RunnerNames = @('node.exe','cmd.exe','powershell.exe','pwsh.exe','bun.exe','deno.exe','python.exe','dotnet.exe')
$RunnerCmdHint = 'npm|pnpm|yarn|bun|vite|next|turbo|nodemon|webpack|astro|remix|nuxt|ng serve|dotnet watch|uvicorn|flask|manage\.py'
$NeverKillRoot = @('explorer.exe','windowsterminal.exe','wt.exe','conhost.exe','openconsole.exe',
    'code.exe','cursor.exe','devenv.exe','services.exe','svchost.exe','wininit.exe','userinit.exe')

function Get-ProjectDir([string]$cmdline, [string]$exePath) {
    if (-not $cmdline) { $cmdline = '' }
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($cmdline, '"([A-Za-z]:\\[^"]+)"|([A-Za-z]:\\[^\s"]+)')) {
        $v = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        $candidates.Add($v)
    }
    foreach ($c in $candidates) {
        $i = $c.IndexOf('\node_modules\', [System.StringComparison]::OrdinalIgnoreCase)
        if ($i -gt 0) { return $c.Substring(0, $i) }
    }
    $home_ = $env:USERPROFILE
    foreach ($c in $candidates) {
        if ($c.StartsWith($home_, [System.StringComparison]::OrdinalIgnoreCase) -and
            $c -notmatch '\\AppData\\|\\node_modules$|\.exe"?$') {
            if (Test-Path -LiteralPath $c -PathType Container) { return $c }
            $d = Split-Path $c -Parent
            if ($d -and $d -ne $home_) { return $d }
        }
    }
    return ''
}

function Get-KillRoot([int]$procId, [hashtable]$procs, [string]$projectDir) {
    $current = $procId
    for ($depth = 0; $depth -lt 8; $depth++) {
        $p = $procs[$current]
        if (-not $p) { break }
        $parentId = [int]$p.ParentProcessId
        if ($parentId -le 4 -or -not $procs.ContainsKey($parentId)) { break }
        $parent = $procs[$parentId]
        $pname = ('' + $parent.Name).ToLower()
        if ($NeverKillRoot -contains $pname) { break }
        $pcmd = '' + $parent.CommandLine
        $sameProject = $projectDir -and $pcmd -and
            $pcmd.IndexOf($projectDir, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        $isRunner = ($RunnerNames -contains $pname) -and ($pcmd -match $RunnerCmdHint)
        if ($sameProject -or $isRunner) { $current = $parentId } else { break }
    }
    return $current
}

function Get-DockerPortMap {
    $map = @{}
    if (-not (Get-Process 'com.docker.backend' -ErrorAction SilentlyContinue)) { return $map }
    try {
        $lines = & docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}' 2>$null
        foreach ($line in @($lines)) {
            $parts = $line -split '\|', 4
            if ($parts.Count -lt 4) { continue }
            $up = ($parts[2] -replace '^Up\s+', '' -replace '\s*\(.*\)$', '')
            foreach ($m in [regex]::Matches($parts[3], ':(\d+)->')) {
                $map[[int]$m.Groups[1].Value] = @{ Name = $parts[0]; Image = $parts[1]; Up = $up }
            }
        }
    } catch { }
    return $map
}

function Format-Uptime([datetime]$start) {
    $ts = (Get-Date) - $start
    if ($ts.TotalDays -ge 1) { return ('{0}d {1}h' -f [int]$ts.TotalDays, $ts.Hours) }
    if ($ts.TotalHours -ge 1) { return ('{0}h {1}m' -f $ts.Hours, $ts.Minutes) }
    return ('{0}m' -f [math]::Max(1, [int]$ts.TotalMinutes))
}

function Format-Mem([long]$bytes) {
    if ($bytes -ge 1GB) { return ('{0:n1} GB' -f ($bytes / 1GB)) }
    return ('{0:n0} MB' -f ($bytes / 1MB))
}

function Get-Scan {
    $procs = @{}
    foreach ($p in (Get-CimInstance Win32_Process)) { $procs[[int]$p.ProcessId] = $p }
    $dockerMap = Get-DockerPortMap

    $seen = @{}
    $groups = @{}
    foreach ($c in (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
        $port = [int]$c.LocalPort
        $ownerPid = [int]$c.OwningProcess
        $dedup = "$port-$ownerPid"
        if ($seen.ContainsKey($dedup)) { continue }
        $seen[$dedup] = $true

        $p = $procs[$ownerPid]
        $name = if ($p) { '' + $p.Name } else { 'unknown' }
        $cmd = if ($p) { '' + $p.CommandLine } else { '' }

        if ($dockerMap.ContainsKey($port)) {
            $info = $dockerMap[$port]
            $key = 'docker:' + $info.Name
            if (-not $groups.ContainsKey($key)) {
                $groups[$key] = @{ Kind = 'docker'; App = $info.Name; Folder = 'image: ' + $info.Image
                    Ports = [System.Collections.Generic.SortedSet[int]]::new()
                    Pids = @{}; DockerName = $info.Name; KillPid = 0; Cmd = $cmd
                    RootName = 'container'; DockerUp = $info.Up }
            }
        } else {
            $isSystem = ($ownerPid -le 4) -or ($SystemNames -contains $name.ToLower())
            $projectDir = if ($isSystem) { '' } else { Get-ProjectDir $cmd ('' + $p.ExecutablePath) }
            $rootPid = if ($isSystem) { $ownerPid } else { Get-KillRoot $ownerPid $procs $projectDir }
            $key = 'pid:' + $rootPid
            if (-not $groups.ContainsKey($key)) {
                $rootName = if ($procs[$rootPid]) { '' + $procs[$rootPid].Name } else { $name }
                $kind = if ($isSystem) { 'system' } elseif ($projectDir) { 'dev' } else { 'app' }
                $app = if ($projectDir) { Split-Path $projectDir -Leaf }
                       else { [System.IO.Path]::GetFileNameWithoutExtension($rootName) }
                $groups[$key] = @{ Kind = $kind; App = $app; Folder = $projectDir
                    Ports = [System.Collections.Generic.SortedSet[int]]::new()
                    Pids = @{}; DockerName = ''; KillPid = $rootPid; Cmd = $cmd; RootName = $rootName }
            }
        }
        [void]$groups[$key].Ports.Add($port)
        $groups[$key].Pids[$ownerPid] = $true
    }

    $kindOrder = @{ dev = 0; docker = 1; app = 2; system = 3 }
    $rows = foreach ($g in $groups.Values) {
        $mem = [long]0; $oldest = Get-Date
        foreach ($procId in $g.Pids.Keys) {
            $p = $procs[$procId]
            if ($p) {
                $mem += [long]$p.WorkingSetSize
                if ($p.CreationDate -and $p.CreationDate -lt $oldest) { $oldest = $p.CreationDate }
            }
        }
        $portList = @($g.Ports)
        [PortApp]@{
            App = $g.App; Ports = ($portList -join ', ')
            Process = ('{0} ({1})' -f $g.RootName, $(if ($g.Kind -eq 'docker') { $g.DockerName } else { $g.KillPid }))
            Folder = $g.Folder
            Uptime = $(if ($g.Kind -eq 'docker') { $g.DockerUp } else { Format-Uptime $oldest })
            Mem = $(if ($g.Kind -eq 'docker') { '' } else { Format-Mem $mem })
            Kind = $g.Kind; Cmd = $(if ($g.Cmd) { $g.Cmd } else { '(command line unavailable)' })
            KillPid = $g.KillPid; DockerName = $g.DockerName
            FirstPort = $portList[0]; SortKey = $kindOrder[$g.Kind]
        }
    }
    return @($rows | Sort-Object SortKey, FirstPort)
}

if ($Smoke) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rows = Get-Scan
    $sw.Stop()
    $rows | Format-Table App, Ports, Process, Kind, Uptime, Mem, Folder -AutoSize | Out-String -Width 220 | Write-Output
    Write-Output ("{0} rows in {1:n1}s" -f $rows.Count, $sw.Elapsed.TotalSeconds)
    exit 0
}

# ---------------------------------------------------------------- UI ----
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Dev Ports" Width="1060" Height="560" WindowStartupLocation="CenterScreen"
        Background="#1E2030" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <SolidColorBrush x:Key="Text" Color="#CAD3F5"/>
    <SolidColorBrush x:Key="Dim" Color="#8087A2"/>
    <SolidColorBrush x:Key="Panel" Color="#24273A"/>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#363A4F"/>
      <Setter Property="Foreground" Value="#CAD3F5"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="6,0,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#494D64"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="#6E738D"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#1E2030"/>
      <Setter Property="Foreground" Value="#8087A2"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="BorderBrush" Value="#363A4F"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#3B4261"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="DataGridRow">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#CAD3F5"/>
      <Setter Property="ToolTip" Value="{Binding Cmd}"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding Kind}" Value="docker"><Setter Property="Foreground" Value="#7DC4E4"/></DataTrigger>
        <DataTrigger Binding="{Binding Kind}" Value="dev"><Setter Property="Foreground" Value="#A6DA95"/></DataTrigger>
        <DataTrigger Binding="{Binding Kind}" Value="system"><Setter Property="Foreground" Value="#6E738D"/></DataTrigger>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#2A2E45"/></Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>
  <DockPanel Margin="12">
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
      <Button x:Name="BtnStop" DockPanel.Dock="Right" Background="#5B3344" Content="&#x25A0;  Stop"/>
      <Button x:Name="BtnCopy" DockPanel.Dock="Right" Content="Copy URL"/>
      <Button x:Name="BtnBrowse" DockPanel.Dock="Right" Content="Open in Browser"/>
      <Button x:Name="BtnFolder" DockPanel.Dock="Right" Content="Open Folder"/>
      <Button x:Name="BtnRefresh" DockPanel.Dock="Right" Content="&#x21BB;  Refresh"/>
      <CheckBox x:Name="ChkSystem" DockPanel.Dock="Right" Content="System" Foreground="#8087A2"
                VerticalAlignment="Center" Margin="12,0,6,0"/>
      <TextBox x:Name="TxtFilter" Background="#24273A" Foreground="#CAD3F5" BorderThickness="0"
               Padding="10,7" VerticalContentAlignment="Center" CaretBrush="#CAD3F5"/>
    </DockPanel>
    <TextBlock x:Name="Status" DockPanel.Dock="Bottom" Foreground="#8087A2" Margin="2,10,0,0"/>
    <DataGrid x:Name="Grid" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single"
              SelectionUnit="FullRow" HeadersVisibility="Column" GridLinesVisibility="None"
              Background="#24273A" BorderThickness="0" RowHeaderWidth="0"
              CanUserResizeRows="False" HorizontalScrollBarVisibility="Auto">
      <DataGrid.Columns>
        <DataGridTextColumn Header="App" Binding="{Binding App}" Width="190"/>
        <DataGridTextColumn Header="Ports" Binding="{Binding Ports}" Width="150">
          <DataGridTextColumn.ElementStyle>
            <Style TargetType="TextBlock"><Setter Property="FontFamily" Value="Consolas"/></Style>
          </DataGridTextColumn.ElementStyle>
        </DataGridTextColumn>
        <DataGridTextColumn Header="Process" Binding="{Binding Process}" Width="170"/>
        <DataGridTextColumn Header="Type" Binding="{Binding Kind}" Width="70"/>
        <DataGridTextColumn Header="Uptime" Binding="{Binding Uptime}" Width="80"/>
        <DataGridTextColumn Header="Mem" Binding="{Binding Mem}" Width="80"/>
        <DataGridTextColumn Header="Folder" Binding="{Binding Folder}" Width="*"/>
      </DataGrid.Columns>
    </DataGrid>
  </DockPanel>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
$grid = $window.FindName('Grid')
$status = $window.FindName('Status')
$txtFilter = $window.FindName('TxtFilter')
$chkSystem = $window.FindName('ChkSystem')

$script:allRows = @()
$script:lastScan = [datetime]::MinValue

function Update-View([bool]$rescan) {
    if ($rescan) {
        $status.Text = 'Scanning...'
        $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try { $script:allRows = Get-Scan } catch { $status.Text = "Scan failed: $_"; return }
        $sw.Stop()
        $script:lastScan = Get-Date
        $script:scanSecs = $sw.Elapsed.TotalSeconds
    }
    $rows = $script:allRows
    if (-not $chkSystem.IsChecked) { $rows = @($rows | Where-Object { $_.Kind -ne 'system' }) }
    $f = $txtFilter.Text
    if ($f) {
        $rows = @($rows | Where-Object {
            $_.App -like "*$f*" -or $_.Ports -like "*$f*" -or $_.Process -like "*$f*" -or $_.Folder -like "*$f*"
        })
    }
    $grid.ItemsSource = $rows
    $portCount = ($rows | ForEach-Object { ($_.Ports -split ',').Count } | Measure-Object -Sum).Sum
    $status.Text = '{0} apps - {1} ports - scanned {2:HH:mm:ss} ({3:n1}s) - double-click a row to open it in the browser' -f
        $rows.Count, [int]$portCount, $script:lastScan, $script:scanSecs
}

function Get-SelectedRow {
    $row = $grid.SelectedItem
    if (-not $row) { $status.Text = 'Select a row first.' }
    return $row
}

$window.FindName('BtnRefresh').Add_Click({ Update-View $true })
$txtFilter.Add_TextChanged({ Update-View $false })
$chkSystem.Add_Click({ Update-View $false })

$window.FindName('BtnFolder').Add_Click({
    $row = Get-SelectedRow; if (-not $row) { return }
    if ($row.Folder -and (Test-Path -LiteralPath $row.Folder)) { Start-Process explorer.exe $row.Folder }
    else { $status.Text = 'No folder known for this row.' }
})

$window.FindName('BtnBrowse').Add_Click({
    $row = Get-SelectedRow; if (-not $row) { return }
    Start-Process "http://localhost:$($row.FirstPort)"
})
$grid.Add_MouseDoubleClick({
    $row = $grid.SelectedItem
    if ($row) { Start-Process "http://localhost:$($row.FirstPort)" }
})

$window.FindName('BtnCopy').Add_Click({
    $row = Get-SelectedRow; if (-not $row) { return }
    $urls = ($row.Ports -split ',\s*' | ForEach-Object { "http://localhost:$_" }) -join "`r`n"
    [Windows.Clipboard]::SetText($urls)
    $status.Text = "Copied: $($urls -replace "`r`n", '  ')"
})

$window.FindName('BtnStop').Add_Click({
    $row = Get-SelectedRow; if (-not $row) { return }
    if ($row.Kind -eq 'docker') {
        $ans = [Windows.MessageBox]::Show(
            "Stop Docker container '$($row.DockerName)'?`n`nPorts: $($row.Ports)",
            'Dev Ports', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { return }
        $status.Text = "Stopping container $($row.DockerName)..."
        $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
        try { & docker stop -t 2 $row.DockerName *> $null } catch { }
        Start-Sleep -Milliseconds 500
        Update-View $true
        return
    }
    if ($row.KillPid -le 4) { $status.Text = 'That is a Windows kernel listener - not killable.'; return }
    $warn = if ($row.Kind -eq 'system') { "`n`nWARNING: this looks like a Windows system process." } else { '' }
    $ans = [Windows.MessageBox]::Show(
        "Stop '$($row.App)'?`n`nKills $($row.Process) and its whole process tree.`nPorts: $($row.Ports)$warn",
        'Dev Ports', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { return }
    $out = & taskkill /PID $row.KillPid /T /F 2>&1
    if ($LASTEXITCODE -ne 0) {
        [Windows.MessageBox]::Show("taskkill failed:`n$out`n`nTry running Dev Ports as administrator.",
            'Dev Ports', 'OK', 'Error') | Out-Null
    }
    Start-Sleep -Milliseconds 400
    Update-View $true
})

# Refresh automatically when you come back to the window
$window.Add_Activated({
    if (((Get-Date) - $script:lastScan).TotalSeconds -gt 5) { Update-View $true }
})

$window.Add_ContentRendered({ Update-View $true })
[void]$window.ShowDialog()
