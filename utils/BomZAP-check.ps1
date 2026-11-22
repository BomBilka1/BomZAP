# Read-only connectivity checks; they do not change the running strategy.
param([int]$TimeoutSeconds = 8)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Write-Host 'curl.exe was not found. Windows 10 or 11 with curl is required.' -ForegroundColor Red
    exit 1
}
$targets = @(
    @{ Name = 'Discord'; Url = 'https://discord.com/' },
    @{ Name = 'YouTube'; Url = 'https://www.youtube.com/' },
    @{ Name = 'Riot website'; Url = 'https://www.riotgames.com/' }
)

Write-Host 'BomZAP connectivity check (current connection and strategy)'
Write-Host 'A website response does not verify Discord voice or a Valorant match.'
Write-Host ''
foreach ($target in $targets) {
    $code = ''
    $curlExit = -1
    try {
        # Windows PowerShell 5.1 can treat native stderr as a terminating error
        # with ErrorActionPreference=Stop, even when stderr is redirected.
        $ErrorActionPreference = 'Continue'
        $code = & curl.exe --silent --location --max-time $TimeoutSeconds `
            --output NUL --write-out '%{http_code}' $target.Url 2>$null
        $curlExit = $LASTEXITCODE
    } catch {
        $curlExit = -1
    } finally {
        $ErrorActionPreference = 'Stop'
    }
    if ($curlExit -ne 0 -or $code -notmatch '^\d{3}$' -or $code -eq '000') {
        Write-Host ("{0}: connection failed (curl exit {1})" -f $target.Name, $curlExit) -ForegroundColor Red
    } elseif ([int]$code -ge 200 -and [int]$code -lt 400) {
        Write-Host ("{0}: HTTP {1}" -f $target.Name, $code) -ForegroundColor Green
    } else {
        Write-Host ("{0}: HTTP {1} (check manually)" -f $target.Name, $code) -ForegroundColor Yellow
    }
}
Write-Host ''
Write-Host 'Valorant login, match latency, packet loss and Discord voice require separate checks.'
