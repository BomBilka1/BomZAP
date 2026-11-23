param([switch]$Restore)
$ErrorActionPreference = 'Stop'
$taskName = 'BomZAP Secure DNS'
$installDir = Join-Path $env:ProgramData 'BomZAP\SecureDNS'
$backupPath = Join-Path $installDir 'previous-dns.json'
$exePath = Join-Path $installDir 'dnsproxy.exe'
$expectedHash = '03258e73a4e771ecc558410833b2f419fcb9549458bb5e91696af1e996dfaf9a'
$createdTask = $false
$dnsChanged = $false
$backup = $null

function Get-IPv4Object($index) {
    $item = @(Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop)
    if ($item.Count -ne 1) { throw 'Could not identify IPv4 DNS configuration.' }
    return $item[0]
}
function Restore-Adapter($saved) {
    $adapter = @(Get-NetAdapter -IncludeHidden | Where-Object { $_.InterfaceGuid.ToString() -eq $saved.InterfaceGuid })
    if ($adapter.Count -ne 1) { throw 'Original network adapter was not found. Backup was kept.' }
    $v4 = Get-IPv4Object $adapter[0].ifIndex
    if ($saved.Automatic) { Set-DnsClientServerAddress -InputObject $v4 -ResetServerAddresses -ErrorAction Stop }
    else {
        $addresses = @($saved.StaticAddresses | Where-Object { $_ })
        if ($addresses.Count -eq 0) { throw 'Backup has no previous static DNS addresses.' }
        Set-DnsClientServerAddress -InputObject $v4 -ServerAddresses $addresses -ErrorAction Stop
    }
    Clear-DnsClientCache
}
function Stop-OwnedTask {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
    }
}
function Assert-LocalDns {
    for ($attempt=1; $attempt -le 10; $attempt++) {
        try {
            $records = @(Resolve-DnsName -Name 'www.youtube.com' -Server '127.0.0.1' -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' -and $_.IPAddress })
            if ($records.Count -gt 0) { return }
        } catch { }
        Start-Sleep -Seconds 2
    }
    throw 'Local DNS could not resolve YouTube through Google HTTPS; adapter DNS was not changed.'
}
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Open PowerShell as Administrator.' }
    if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { throw 'This package requires 64-bit x64 Windows.' }
    if ($Restore) {
        if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw 'No previous DNS backup was found.' }
        $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
        Restore-Adapter $backup
        Stop-OwnedTask
        Remove-Item -LiteralPath $backupPath -Force
        Write-Host 'Previous IPv4 DNS settings restored; secure DNS startup task removed.' -ForegroundColor Green
        return
    }
    if (Test-Path -LiteralPath $backupPath) { throw 'Existing DNS backup found. Run this script with -Restore first.' }
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw 'A task with this name already exists. No changes were made.' }
    if ((Test-Path -LiteralPath $exePath -PathType Leaf) -and (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) {
        throw 'A different dnsproxy.exe already exists in the target folder. No changes were made.'
    }
    $source = Join-Path $PSScriptRoot 'dnsproxy.exe'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'dnsproxy.exe is missing next to this script. Extract the entire package.' }
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) { throw 'dnsproxy.exe checksum mismatch. No changes were made.' }
    $adapters = @(Get-NetAdapter | Where-Object Status -eq 'Up' | Sort-Object ifIndex)
    if ($adapters.Count -eq 0) { throw 'No active network adapters found.' }
    Write-Host 'Select the internet adapter (Wi-Fi or Ethernet):'
    for ($i=0; $i -lt $adapters.Count; $i++) { Write-Host ("  {0}. {1} ({2})" -f ($i+1), $adapters[$i].Name, $adapters[$i].InterfaceDescription) }
    $choice = 0
    if (-not [int]::TryParse((Read-Host 'Adapter number'), [ref]$choice) -or $choice -lt 1 -or $choice -gt $adapters.Count) { throw 'Invalid adapter selection; no changes were made.' }
    $adapter = $adapters[$choice-1]
    $v4 = Get-IPv4Object $adapter.ifIndex
    $guid = $adapter.InterfaceGuid.ToString()
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{' + $guid.Trim('{}') + '}'
    $staticRaw = (Get-ItemProperty -LiteralPath $key -Name NameServer -ErrorAction SilentlyContinue).NameServer
    $static = @(([string]$staticRaw -split '[,\s]+' | Where-Object { $_ }))
    $backup = [PSCustomObject]@{ InterfaceGuid=$guid; InterfaceName=$adapter.Name; Automatic=($static.Count -eq 0); StaticAddresses=$static; PreviousAddresses=@($v4.ServerAddresses) }
    # Check both DNS transports before saving any changes.
    $tcp = $null; $udp = $null
    try {
        $tcp = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse('127.0.0.1'),53); $tcp.Start()
        $udp = New-Object Net.Sockets.UdpClient; $udp.Client.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Parse('127.0.0.1'),53)))
    } catch { throw 'Local DNS port 53 is already in use. No changes were made.' }
    finally { if ($tcp) { $tcp.Stop() }; if ($udp) { $udp.Close() } }
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    $backup | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $backupPath -Encoding UTF8
    Copy-Item -LiteralPath $source -Destination $exePath -Force
    $action = New-ScheduledTaskAction -Execute $exePath -Argument '--listen=127.0.0.1 --port=53 --upstream=https://dns.google/dns-query --bootstrap=8.8.8.8:53'
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
    $createdTask = $true
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    Assert-LocalDns
    # Change IPv4 on the selected adapter only; the IPv6 CIM object is untouched.
    $dnsChanged = $true
    Set-DnsClientServerAddress -InputObject $v4 -ServerAddresses @('127.0.0.1') -ErrorAction Stop
    Clear-DnsClientCache
    $answer = @(Resolve-DnsName -Name 'www.youtube.com' -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' -and $_.IPAddress })
    if ($answer.Count -eq 0) { throw 'Windows could not resolve YouTube after applying DNS.' }
    Write-Host "Secure DNS is active on adapter: $($adapter.Name)" -ForegroundColor Green
    Write-Host 'IPv6 and other adapters were not changed; they may use different DNS.'
    Write-Host 'Run curl.exe -4 -I --max-time 15 https://www.youtube.com/ with your BomZAP strategy active.'
    Write-Host "To undo, run this script with -Restore. Previous settings: $backupPath"
} catch {
    $message = $_.Exception.Message
    if ($dnsChanged -and $backup) {
        try { Restore-Adapter $backup; $dnsChanged=$false }
        catch { Write-Host "RESTORE FAILED: $($_.Exception.Message). Keep this window; backup: $backupPath" -ForegroundColor Red }
    }
    if (-not $dnsChanged -and $createdTask) {
        try { Stop-OwnedTask; if (Test-Path $backupPath) { Remove-Item -LiteralPath $backupPath -Force } }
        catch { Write-Host "Could not remove DNS task: $($_.Exception.Message). Backup kept at $backupPath" -ForegroundColor Red }
    } elseif (-not $dnsChanged -and -not $createdTask -and $backup -and (Test-Path $backupPath)) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
    Write-Host "ERROR: $message" -ForegroundColor Red
    exit 1
}
