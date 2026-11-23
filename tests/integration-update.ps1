$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$tempRoot = Join-Path $env:TEMP ('bomzap-integration-' + [guid]::NewGuid().ToString('N'))
$install = Join-Path $tempRoot 'installed'; $pack = Join-Path $tempRoot 'pack'; $source = Join-Path $pack 'BomZAP'
$oldProgramData = $env:ProgramData
try {
    foreach ($dir in @($install, (Join-Path $install 'utils'), (Join-Path $install 'lists'), (Join-Path $install 'bin'), (Join-Path $source 'utils'), (Join-Path $source 'lists'), (Join-Path $source 'bin'))) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item (Join-Path $repositoryRoot 'utils\BomZAP-update.ps1') (Join-Path $install 'utils\BomZAP-update.ps1')
    Copy-Item (Join-Path $repositoryRoot 'utils\BomZAP-update.ps1') (Join-Path $source 'utils\BomZAP-update.ps1')
    [IO.File]::WriteAllText((Join-Path $install '.bomzap-version'), '1.0.0')
    [IO.File]::WriteAllText((Join-Path $install 'lists\list-bomzap-personal.txt'), "my.example`r`n")
    [IO.File]::WriteAllText((Join-Path $install 'lists\ipset-all.txt'), "203.0.113.113/32`r`n")
    [IO.File]::WriteAllText((Join-Path $source '.bomzap-version'), '1.1.0')
    [IO.File]::WriteAllText((Join-Path $source 'lists\list-bomzap-personal.txt'), "riotgames.com`r`n")
    [IO.File]::WriteAllText((Join-Path $source 'lists\ipset-all.txt'), "SHOULD-NOT-REPLACE`r`n")
    [IO.File]::WriteAllText((Join-Path $source 'bin\winws.exe'), 'dummy executable')
    [IO.File]::WriteAllText((Join-Path $source 'service.bat'), 'dummy service')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fixtureZip = Join-Path $tempRoot 'fixture.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($pack,$fixtureZip)
    $digest = (Get-FileHash $fixtureZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $env:ProgramData = Join-Path $tempRoot 'programdata'
    function Invoke-RestMethod { param($Uri,$Headers,$TimeoutSec) [PSCustomObject]@{draft=$false;prerelease=$false;tag_name='v1.1.0';assets=@([PSCustomObject]@{name='BomZAP-v1.1.0.zip';digest=('sha256:'+$digest);browser_download_url='https://github.com/BomBilka1/BomZAP/releases/download/v1.1.0/BomZAP-v1.1.0.zip'})} }
    function Invoke-WebRequest { param($Uri,$OutFile,[switch]$UseBasicParsing,$TimeoutSec) Copy-Item $fixtureZip $OutFile }
    $global:LASTEXITCODE = 0
    & (Join-Path $install 'utils\BomZAP-update.ps1')
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw 'Updater failed.' }
    if ((Get-Content (Join-Path $install '.bomzap-version') -Raw).Trim() -ne '1.1.0') { throw 'Version not updated.' }
    $personal = Get-Content (Join-Path $install 'lists\list-bomzap-personal.txt')
    if ('my.example' -notin $personal -or 'riotgames.com' -notin $personal) { throw 'Personal list was not merged.' }
    if ((Get-Content (Join-Path $install 'lists\ipset-all.txt') -Raw) -notmatch '203.0.113.113') { throw 'IPSet setting changed.' }
    if (Test-Path (Join-Path $env:ProgramData 'BomZAP\update\journal.json')) { throw 'Journal remains after success.' }
    & (Join-Path $install 'utils\BomZAP-update.ps1') -Register
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw 'Registration failed.' }
    $task = Get-ScheduledTask -TaskName 'BomZAP Auto Update' -ErrorAction Stop
    if ($task.Actions.Arguments -notmatch 'BomZAP-update\.ps1') { throw 'Scheduled updater points to the wrong file.' }
    Write-Host 'Simulated update, version check, settings and personal list passed.'
} finally {
    Unregister-ScheduledTask -TaskName 'BomZAP Auto Update' -Confirm:$false -ErrorAction SilentlyContinue
    $env:ProgramData=$oldProgramData
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
