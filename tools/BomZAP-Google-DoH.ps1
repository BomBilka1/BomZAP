param([switch]$Restore)
$ErrorActionPreference = 'Stop'
$backupDir = Join-Path $env:ProgramData 'BomZAP'
$backupFile = Join-Path $backupDir 'google-doh-backup.json'
$servers = @('8.8.8.8', '8.8.4.4')
$template = 'https://dns.google/dns-query'

function Restore-Settings($items) {
    foreach ($item in $items) {
        $current = Get-DnsClientDohServerAddress -ServerAddress $item.Address -ErrorAction SilentlyContinue
        if ($item.Existed) {
            $options = @{ ServerAddress=$item.Address; DohTemplate=$item.Template; AutoUpgrade=[bool]$item.AutoUpgrade; AllowFallbackToUdp=[bool]$item.AllowFallbackToUdp; ErrorAction='Stop' }
            if ($current) { Set-DnsClientDohServerAddress @options | Out-Null }
            else { Add-DnsClientDohServerAddress @options | Out-Null }
        } elseif ($current) {
            Remove-DnsClientDohServerAddress -ServerAddress $item.Address -ErrorAction Stop | Out-Null
        }
    }
}
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Open PowerShell as Administrator.' }
    $os = Get-CimInstance Win32_OperatingSystem
    if ($os.ProductType -eq 1 -and [int]$os.BuildNumber -lt 22000) { throw 'This script requires Windows 11. Windows 10 needs a different solution.' }
    foreach ($command in @('Get-DnsClientDohServerAddress','Set-DnsClientDohServerAddress','Add-DnsClientDohServerAddress','Remove-DnsClientDohServerAddress')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required Windows DNS command is missing: $command" }
    }
    if ($Restore) {
        if (-not (Test-Path -LiteralPath $backupFile)) { throw 'No backup found on this computer.' }
        $parsed = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($backupFile))
        $snapshot = @($parsed | ForEach-Object { $_ })
        if ($snapshot.Count -ne 2 -or @($snapshot | Where-Object { $_.Address -notin $servers }).Count -ne 0) { throw 'Invalid backup; no settings changed.' }
        Restore-Settings $snapshot
        Remove-Item -LiteralPath $backupFile -Force
        Clear-DnsClientCache
        Write-Host 'Previous Google DoH settings restored. Adapter DNS addresses were not changed.' -ForegroundColor Green
        return
    }
    if (Test-Path -LiteralPath $backupFile) { throw 'A backup already exists. Restore first; it will not be overwritten.' }
    $snapshot = foreach ($ip in $servers) {
        $old = Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue
        if ($old) { [PSCustomObject]@{Address=$ip;Existed=$true;Template=$old.DohTemplate;AutoUpgrade=$old.AutoUpgrade;AllowFallbackToUdp=$old.AllowFallbackToUdp} }
        else { [PSCustomObject]@{Address=$ip;Existed=$false;Template=$null;AutoUpgrade=$false;AllowFallbackToUdp=$false} }
    }
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $snapshot | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $backupFile -Encoding UTF8
    try {
        foreach ($ip in $servers) {
            $current = Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue
            $options = @{ ServerAddress=$ip; DohTemplate=$template; AutoUpgrade=$true; AllowFallbackToUdp=$false; ErrorAction='Stop' }
            if ($current) { Set-DnsClientDohServerAddress @options | Out-Null }
            else { Add-DnsClientDohServerAddress @options | Out-Null }
        }
    } catch {
        $message = $_.Exception.Message
        try { Restore-Settings $snapshot; Remove-Item -LiteralPath $backupFile -Force }
        catch { throw "Setup failed: $message. Restore also failed: $($_.Exception.Message). Backup: $backupFile" }
        throw "Setup failed; previous DoH settings restored: $message"
    }
    try { Clear-DnsClientCache } catch { Write-Warning 'Could not clear the DNS cache.' }
    Write-Host 'Encrypted DNS configured for Google IPv4 DNS (8.8.8.8 and 8.8.4.4).' -ForegroundColor Green
    Write-Host 'The script did not change adapter DNS addresses or IPv6 settings.'
    Write-Host 'Active adapters and their DNS servers:'
    try {
        Get-NetAdapter | Where-Object Status -eq 'Up' | ForEach-Object {
            $adapter = $_
            Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue | ForEach-Object {
                Write-Host ("  {0} / {1}: {2}" -f $adapter.Name, $_.AddressFamily, ($_.ServerAddresses -join ', '))
            }
        }
    } catch { Write-Warning 'Could not display adapter DNS settings.' }
    Write-Host 'Other DNS servers or adapters may still be used. Test with:'
    Write-Host '  curl.exe -4 -I --max-time 15 https://www.youtube.com/'
    Write-Host "To restore Google DoH settings, run this script with -Restore. Backup: $backupFile"
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
