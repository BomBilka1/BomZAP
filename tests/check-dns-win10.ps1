$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$source = Join-Path $root 'tools\BomZAP-DNS-Win10.ps1'
$tokens=$null; $errors=$null
[void][Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { $errors | ForEach-Object { Write-Error $_ }; exit 1 }
$tempRoot = Join-Path $env:TEMP ('bomzap-dns-test-' + [guid]::NewGuid().ToString('N'))
$originalProgramData = $env:ProgramData
$env:ProgramData = Join-Path $tempRoot 'programdata'
$scriptPath = Join-Path $tempRoot 'BomZAP-DNS-Win10.ps1'
try {
    if (Get-ScheduledTask -TaskName 'BomZAP Secure DNS' -ErrorAction SilentlyContinue) { throw 'Test runner has an existing DNS task.' }
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    Copy-Item $source $scriptPath
    $url = 'https://github.com/AdguardTeam/dnsproxy/releases/download/v0.86.0/dnsproxy-windows-amd64-v0.86.0.zip'
    $zip = Join-Path $tempRoot 'official.zip'
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 120
    if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'dedc186ddd4b96bf92474f91d972f67da0824e0141d09e3102fd96db9f8a0dbc') { throw 'Official ZIP checksum mismatch.' }
    Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tempRoot 'unpacked')
    Copy-Item (Join-Path $tempRoot 'unpacked\windows-amd64\dnsproxy.exe') (Join-Path $tempRoot 'dnsproxy.exe')
    $adapters = @(Get-NetAdapter | Where-Object Status -eq 'Up' | Sort-Object ifIndex)
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1
    $chosen = -1
    for ($i=0; $i -lt $adapters.Count; $i++) { if ($adapters[$i].ifIndex -eq $route.ifIndex) { $chosen=$i; break } }
    if ($chosen -lt 0) { throw 'Default network adapter not found.' }
    $choiceForTest = [string]($chosen+1)
    function Read-Host { param($Prompt) return $choiceForTest }
    $beforeV4 = @((Get-DnsClientServerAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4).ServerAddresses)
    $beforeV6 = @((Get-DnsClientServerAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv6).ServerAddresses)
    $global:LASTEXITCODE = 0
    & $scriptPath
    if ($LASTEXITCODE -ne 0) { throw 'Secure DNS installation failed.' }
    $current = @((Get-DnsClientServerAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4).ServerAddresses)
    if ($current.Count -ne 1 -or $current[0] -ne '127.0.0.1') { throw 'Local DNS was not applied.' }
    $v6 = @((Get-DnsClientServerAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv6).ServerAddresses)
    if (Compare-Object $beforeV6 $v6) { throw 'IPv6 DNS changed unexpectedly.' }
    if (-not (Get-ScheduledTask -TaskName 'BomZAP Secure DNS' -ErrorAction SilentlyContinue)) { throw 'Startup task missing.' }
    & $scriptPath -Restore
    if ($LASTEXITCODE -ne 0) { throw 'DNS restore failed.' }
    $afterV4 = @((Get-DnsClientServerAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4).ServerAddresses)
    if (Compare-Object $beforeV4 $afterV4) { throw 'IPv4 DNS was not restored.' }
    if (Get-ScheduledTask -TaskName 'BomZAP Secure DNS' -ErrorAction SilentlyContinue) { throw 'Startup task was not removed.' }
    Write-Host 'Local DNS proxy startup, DNS resolution, adapter setup and rollback passed.'
} finally {
    if (Test-Path (Join-Path $env:ProgramData 'BomZAP\SecureDNS\previous-dns.json')) { & $scriptPath -Restore }
    $env:ProgramData = $originalProgramData
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
