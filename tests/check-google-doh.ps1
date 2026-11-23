$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script = Join-Path $root 'tools\BomZAP-Google-DoH.ps1'
$tokens=$null; $errors=$null
[void][Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
if ($errors.Count) { $errors | ForEach-Object { Write-Error $_ }; exit 1 }
$originalProgramData = $env:ProgramData
$env:ProgramData = Join-Path $env:TEMP ('bomzap-doh-test-' + [guid]::NewGuid().ToString('N'))
try {
    $before = foreach ($ip in @('8.8.8.8','8.8.4.4')) {
        $s = Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue
        if ($s) { "${ip}|$($s.DohTemplate)|$($s.AutoUpgrade)|$($s.AllowFallbackToUdp)" } else { "${ip}|missing" }
    }
    $global:LASTEXITCODE = 0
    & $script
    if ($LASTEXITCODE -ne 0) { throw 'Setup failed.' }
    foreach ($ip in @('8.8.8.8','8.8.4.4')) {
        $s = Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction Stop
        if ($s.DohTemplate -ne 'https://dns.google/dns-query' -or -not $s.AutoUpgrade -or $s.AllowFallbackToUdp) { throw "Incorrect DoH settings for $ip" }
    }
    & $script -Restore
    if ($LASTEXITCODE -ne 0) { throw 'Restore failed.' }
    $after = foreach ($ip in @('8.8.8.8','8.8.4.4')) {
        $s = Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue
        if ($s) { "${ip}|$($s.DohTemplate)|$($s.AutoUpgrade)|$($s.AllowFallbackToUdp)" } else { "${ip}|missing" }
    }
    if (Compare-Object $before $after) { throw 'Original DoH settings differ after restore.' }
    Write-Host 'Google DoH setup and restore passed.'
} finally {
    if (Test-Path (Join-Path $env:ProgramData 'BomZAP\google-doh-backup.json')) { & $script -Restore }
    Remove-Item -LiteralPath $env:ProgramData -Recurse -Force -ErrorAction SilentlyContinue
    $env:ProgramData = $originalProgramData
}
