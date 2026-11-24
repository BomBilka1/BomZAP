# Automatic web connectivity selection. Requires Windows PowerShell 5.1 and elevation.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root 'bin\winws.exe'
$serviceName = 'zapret'
$targets = @(
    @{ Name='Discord'; Url='https://discord.com/' },
    @{ Name='YouTube'; Url='https://www.youtube.com/' },
    @{ Name='Riot'; Url='https://www.riotgames.com/' }
)
$oldService = $null
$oldRunning = $false
$serviceTouched = $false
$createdService = $false
$serviceReconfigured = $false
$installed = $false
$testProcess = $null

function Require-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run service-auto-select.bat as administrator.'
    }
}
function Get-ServiceInfo {
    Get-CimInstance Win32_Service -Filter "Name='zapret'" -ErrorAction Stop
}
function Set-ServiceBinaryPath($path, $mode) {
    if (-not ('BomZap.ServiceConfig' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace BomZap {
    public static class ServiceConfig {
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern IntPtr OpenSCManager(string machine, string database, uint access);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern IntPtr OpenService(IntPtr manager, string service, uint access);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool ChangeServiceConfig(IntPtr service, uint type, uint start, uint error,
            string path, string group, IntPtr tag, string dependencies, string account, string password, string display);
        [DllImport("advapi32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool CloseServiceHandle(IntPtr handle);
        public static void Set(string name, string path, uint start) {
            IntPtr manager = OpenSCManager(null, null, 1);
            if (manager == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                IntPtr service = OpenService(manager, name, 2);
                if (service == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                try {
                    if (!ChangeServiceConfig(service, 0xffffffff, start, 0xffffffff, path, null,
                        IntPtr.Zero, null, null, null, null)) throw new Win32Exception(Marshal.GetLastWin32Error());
                } finally { CloseServiceHandle(service); }
            } finally { CloseServiceHandle(manager); }
        }
    }
}
'@
    }
    $start = switch ($mode) { 'Auto' {2} 'Automatic' {2} 'Manual' {3} 'Disabled' {4} default { throw "Unsupported service start mode: $mode" } }
    [BomZap.ServiceConfig]::Set($serviceName, $path, [uint32]$start)
}
function Restore-OldService($old, $wasRunning, $configChanged) {
    $current = Get-ServiceInfo
    if (-not $current) { throw 'Previous service is missing.' }
    if ($configChanged) {
        if ($current.State -eq 'Running') { Stop-Service -Name $serviceName -Force; Wait-ServiceState $serviceName 'Stopped' }
        Set-ServiceBinaryPath $old.PathName $old.StartMode
        $current = Get-ServiceInfo
    }
    if ($wasRunning -and $current.State -ne 'Running') { Start-Service -Name $serviceName; Wait-ServiceState $serviceName 'Running' }
}
function Wait-ServiceState($name, $state) {
    $s = Get-Service -Name $name -ErrorAction Stop
    $s.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::$state, [TimeSpan]::FromSeconds(20))
}
function Stop-TestProcess {
    if ($null -ne $script:testProcess) {
        if (-not $script:testProcess.HasExited) { Stop-Process -Id $script:testProcess.Id -Force -ErrorAction SilentlyContinue }
        $script:testProcess = $null
        Start-Sleep -Milliseconds 500
    }
}
function Read-Strategy($file) {
    $lines = Get-Content -LiteralPath $file.FullName
    $index = -1
    for ($i=0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*start\s+.*?winws\.exe"\s+(.+)$') { $index=$i; break }
    }
    if ($index -lt 0) { throw 'winws command not found' }
    $parts = New-Object System.Collections.Generic.List[string]
    [void]$parts.Add($matches[1].TrimEnd(' ', '^'))
    for ($i=$index+1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if (-not $line.StartsWith('--')) { break }
        [void]$parts.Add($line.TrimEnd(' ', '^'))
    }
    $args = $parts -join ' '
    $vars = @{
        'BIN'=(Join-Path $root 'bin') + '\';
        'LISTS'=(Join-Path $root 'lists') + '\';
        'GameFilter'='12'; 'GameFilterTCP'='12'; 'GameFilterUDP'='12'
    }
    $args = [regex]::Replace($args, '%([^%]+)%', {
        param($match)
        $key = $match.Groups[1].Value
        if (-not $vars.ContainsKey($key)) { throw "Unsupported variable: $key" }
        return $vars[$key]
    })
    if ($args -notmatch '^--wf-tcp=' -or $args -notmatch '--wf-udp=') { throw 'Unexpected strategy format' }
    return $args
}
function Add-PersonalProfile($strategyArgs, $personalRule) {
    if ($strategyArgs -match 'list-bomzap-personal\.txt') { return $strategyArgs }
    $offset = $strategyArgs.IndexOf(' --filter-')
    if ($offset -lt 0) { throw 'Could not find strategy profiles.' }
    return $strategyArgs.Substring(0, $offset) + ' ' + $personalRule + $strategyArgs.Substring($offset)
}
function Test-Target($url) {
    try {
        $ErrorActionPreference = 'Continue'
        $output = & curl.exe --silent --location --max-time 10 --output NUL --write-out '%{http_code} %{time_total}' $url 2>$null
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = 'Stop' }
    if ($code -ne 0 -or $output -notmatch '^(\d{3})\s+([0-9.]+)$') { return $null }
    $status = [int]$matches[1]
    if ($status -lt 200 -or $status -ge 400) { return $null }
    return [double]::Parse($matches[2], [Globalization.CultureInfo]::InvariantCulture)
}
try {
    Require-Admin
    if (-not (Test-Path -LiteralPath $bin)) { throw 'winws.exe not found. Extract the complete archive first.' }
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'curl.exe not found.' }
    $gameFlag = Join-Path $root 'utils\game_filter.enabled'
    if (Test-Path $gameFlag) {
        $gameLines = @(Get-Content -LiteralPath $gameFlag)
        if (-not ($gameLines -match '^\s*mode\s*=\s*disabled\s*$')) {
            throw 'Disable Game Filter in service.bat before testing; no settings were changed.'
        }
    }
    $ipsetFile = Join-Path $root 'lists\ipset-all.txt'
    if (-not (Test-Path $ipsetFile) -or ([IO.File]::ReadAllText($ipsetFile) -notmatch '203\.0\.113\.113/32')) {
        throw 'Set IPSet Filter to None in service.bat before testing; no settings were changed.'
    }
    foreach ($name in @('ipset-exclude-user.txt','list-general-user.txt','list-exclude-user.txt')) {
        $p = Join-Path (Join-Path $root 'lists') $name
        if (-not (Test-Path $p)) {
            $content = if ($name -eq 'ipset-exclude-user.txt') { '203.0.113.113/32' } else { 'domain.example.abc' }
            [IO.File]::WriteAllText($p, $content + "`r`n")
        }
    }
    $files = @(Get-ChildItem -LiteralPath $root -Filter 'general*.bat' -File | Sort-Object Name)
    if ($files.Count -eq 0) { throw 'No strategy files found.' }
    $personalFile = Get-Item -LiteralPath (Join-Path $root 'general (BomZAP PERSONAL).bat')
    $personalArgs = Read-Strategy $personalFile
    if ($personalArgs -notmatch '(--filter-tcp=80,443\s+--hostlist="[^"]*list-bomzap-personal\.txt".*?--new)(?:\s|$)') {
        throw 'The personal Riot profile was not found; cannot safely retain it.'
    }
    $personalRule = $matches[1]
    Write-Host 'Testing Discord, YouTube and Riot website; game ping and Discord voice are not tested.'
    Write-Host 'Existing zapret service will be temporarily stopped and restored on failure.'
    $oldService = Get-ServiceInfo
    if ($oldService) {
        $oldRunning = $oldService.State -eq 'Running'
        if ($oldService.State -notin @('Running','Stopped')) { throw 'Existing zapret service is changing state. Try again later.' }
        if ($oldRunning) {
            $serviceTouched = $true
            Stop-Service -Name $serviceName -ErrorAction Stop
            Wait-ServiceState $serviceName 'Stopped'
        }
    }
    if (Get-Process -Name winws -ErrorAction SilentlyContinue) { throw 'Another winws process is running. Stop it and retry.' }
    $env:NO_UPDATE_CHECK = '1'
    $results = @()
    foreach ($file in $files) {
        Write-Host "Testing $($file.Name)..."
        try {
            $args = Add-PersonalProfile (Read-Strategy $file) $personalRule
            if ($args -notmatch '--filter-l7=discord,stun') {
                Write-Host '  Skipped: Discord voice rule is missing.'
                continue
            }
            $testProcess = Start-Process -FilePath $bin -ArgumentList $args -WorkingDirectory (Split-Path $bin) -WindowStyle Minimized -PassThru
            Start-Sleep -Seconds 2
            if ($testProcess.HasExited) { Write-Host '  winws exited'; continue }
            $times = @()
            foreach ($target in $targets) {
                $time = Test-Target $target.Url
                if ($null -eq $time) { Write-Host "  $($target.Name): unavailable"; continue }
                Write-Host ("  {0}: {1:N2} s" -f $target.Name, $time)
                $times += $time
            }
            if ($times.Count -eq $targets.Count -and -not $testProcess.HasExited) {
                $results += [PSCustomObject]@{ Name=$file.Name; Args=$args; WebSeconds=($times | Measure-Object -Sum).Sum }
            }
        } catch { Write-Host "  Failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        finally { Stop-TestProcess }
    }
    if ($results.Count -eq 0) { throw 'No strategy passed all three website checks. Previous service will be restored.' }
    $best = $results | Sort-Object WebSeconds, Name | Select-Object -First 1
    Write-Host ("Selected {0}: web response total {1:N2} seconds" -f $best.Name, $best.WebSeconds)
    $binaryPath = '"' + $bin + '" ' + $best.Args
    $serviceTouched = $true
    if ($oldService) {
        Set-ServiceBinaryPath $binaryPath 'Automatic'
        $serviceReconfigured = $true
    } else {
        New-Service -Name $serviceName -BinaryPathName $binaryPath -DisplayName 'zapret' -StartupType Automatic | Out-Null
        $createdService = $true
    }
    Start-Service -Name $serviceName -ErrorAction Stop
    Wait-ServiceState $serviceName 'Running'
    $serviceLabel = 'AUTO + PERSONAL: ' + [IO.Path]::GetFileNameWithoutExtension($best.Name)
    New-ItemProperty -LiteralPath 'HKLM:\System\CurrentControlSet\Services\zapret' -Name 'zapret-discord-youtube' -Value $serviceLabel -PropertyType String -Force | Out-Null
    $installed = $true
    Write-Host "Installed and started: $($best.Name)" -ForegroundColor Green
    Write-Host 'Check Valorant login and in-game ping, and Discord voice manually.' -ForegroundColor Yellow
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Stop-TestProcess
    if (-not $installed -and $serviceTouched) {
        try {
            $current = Get-ServiceInfo
            if ($oldService) {
                Restore-OldService $oldService $oldRunning $serviceReconfigured
            } elseif ($createdService -and $current) {
                if ($current.State -eq 'Running') { Stop-Service -Name $serviceName -Force; Wait-ServiceState $serviceName 'Stopped' }
                $result = Invoke-CimMethod -InputObject (Get-ServiceInfo) -MethodName Delete
                if ($result.ReturnValue -ne 0) { throw "Remove new service failed: $($result.ReturnValue)" }
            }
            Write-Host 'Previous service state restored.'
        } catch { Write-Host "RESTORE FAILED: $($_.Exception.Message). Check service.bat manually." -ForegroundColor Red }
    }
    Remove-Item Env:NO_UPDATE_CHECK -ErrorAction SilentlyContinue
}
