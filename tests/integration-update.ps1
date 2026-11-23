$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$tempRoot = Join-Path $env:TEMP ('bomzap-integration-' + [guid]::NewGuid().ToString('N'))
$install = Join-Path $tempRoot 'installed'; $pack = Join-Path $tempRoot 'pack'; $source = Join-Path $pack 'BomZAP'
$oldProgramData = $env:ProgramData
$createdService = $false
try {
    if (Get-Service -Name 'zapret' -ErrorAction SilentlyContinue) { throw 'Test runner already has a zapret service.' }
    foreach ($dir in @($install, (Join-Path $install 'utils'), (Join-Path $install 'lists'), (Join-Path $install 'bin'), (Join-Path $source 'utils'), (Join-Path $source 'lists'), (Join-Path $source 'bin'))) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item (Join-Path $repositoryRoot 'utils\BomZAP-update.ps1') (Join-Path $install 'utils\BomZAP-update.ps1')
    Copy-Item (Join-Path $repositoryRoot 'utils\BomZAP-update.ps1') (Join-Path $source 'utils\BomZAP-update.ps1')
    [IO.File]::WriteAllText((Join-Path $install '.bomzap-version'), '1.0.0')
    [IO.File]::WriteAllText((Join-Path $install 'lists\list-bomzap-personal.txt'), "my.example`r`n")
    [IO.File]::WriteAllText((Join-Path $install 'lists\ipset-all.txt'), "203.0.113.113/32`r`n")
    [IO.File]::WriteAllText((Join-Path $source '.bomzap-version'), '1.1.0')
    [IO.File]::WriteAllText((Join-Path $source 'lists\list-bomzap-personal.txt'), "riotgames.com`r`n")
    [IO.File]::WriteAllText((Join-Path $source 'lists\ipset-all.txt'), "SHOULD-NOT-REPLACE`r`n")
    $serviceSource = @'
using System.ServiceProcess;
public class BomZapTestService : ServiceBase {
    protected override void OnStart(string[] args) { }
    protected override void OnStop() { }
    public static void Main() { Run(new BomZapTestService()); }
}
'@
    $oldExe = Join-Path $install 'bin\winws.exe'
    $newExe = Join-Path $source 'bin\winws.exe'
    Add-Type -TypeDefinition ($serviceSource.Replace('BomZapTestService','BomZapTestOld')) -ReferencedAssemblies 'System.ServiceProcess.dll' -OutputAssembly $oldExe -OutputType ConsoleApplication
    Add-Type -TypeDefinition ($serviceSource.Replace('BomZapTestService','BomZapTestNew')) -ReferencedAssemblies 'System.ServiceProcess.dll' -OutputAssembly $newExe -OutputType ConsoleApplication
    New-Service -Name 'zapret' -BinaryPathName ('"' + $oldExe + '"') -StartupType Manual | Out-Null
    $createdService = $true
    Start-Service 'zapret'
    (Get-Service 'zapret').WaitForStatus('Running',[TimeSpan]::FromSeconds(20))
    [IO.File]::WriteAllText((Join-Path $source 'service.bat'), 'dummy service')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fixtureZip = Join-Path $tempRoot 'fixture.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($pack,$fixtureZip)
    $digest = (Get-FileHash $fixtureZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $env:ProgramData = Join-Path $tempRoot 'programdata'
    $releaseVersion = '1.1.0'
    function Invoke-RestMethod { param($Uri,$Headers,$TimeoutSec) [PSCustomObject]@{draft=$false;prerelease=$false;tag_name=('v'+$releaseVersion);assets=@([PSCustomObject]@{name=('BomZAP-v'+$releaseVersion+'.zip');digest=('sha256:'+$digest);browser_download_url=('https://github.com/BomBilka1/BomZAP/releases/download/v'+$releaseVersion+'/BomZAP-v'+$releaseVersion+'.zip')})} }
    function Invoke-WebRequest { param($Uri,$OutFile,[switch]$UseBasicParsing,$TimeoutSec) Copy-Item $fixtureZip $OutFile }
    $global:LASTEXITCODE = 0
    & (Join-Path $install 'utils\BomZAP-update.ps1')
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw 'Updater failed.' }
    if ((Get-Content (Join-Path $install '.bomzap-version') -Raw).Trim() -ne '1.1.0') { throw 'Version not updated.' }
    $personal = Get-Content (Join-Path $install 'lists\list-bomzap-personal.txt')
    if ('my.example' -notin $personal -or 'riotgames.com' -notin $personal) { throw 'Personal list was not merged.' }
    if ((Get-Content (Join-Path $install 'lists\ipset-all.txt') -Raw) -notmatch '203.0.113.113') { throw 'IPSet setting changed.' }
    if ((Get-Service 'zapret').Status -ne 'Running') { throw 'Service was not restarted.' }
    if ((Get-FileHash $oldExe -Algorithm SHA256).Hash -ne (Get-FileHash $newExe -Algorithm SHA256).Hash) { throw 'Service binary was not updated.' }
    if (Test-Path (Join-Path $env:ProgramData 'BomZAP\update\journal.json')) { throw 'Journal remains after success.' }
    & (Join-Path $install 'utils\BomZAP-update.ps1') -Register
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw 'Registration failed.' }
    $task = Get-ScheduledTask -TaskName 'BomZAP Auto Update' -ErrorAction Stop
    if ($task.Actions.Arguments -notmatch 'BomZAP-update\.ps1') { throw 'Scheduled updater points to the wrong file.' }
    # Inject a failure after a newer release starts copying files. The old
    # version and the running service must be restored.
    [IO.File]::WriteAllText((Join-Path $source '.bomzap-version'), '1.2.0')
    [IO.File]::WriteAllText((Join-Path $source 'service.bat'), 'new version of service')
    Remove-Item $fixtureZip
    [IO.Compression.ZipFile]::CreateFromDirectory($pack,$fixtureZip)
    $digest = (Get-FileHash $fixtureZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $releaseVersion = '1.2.0'
    $global:BomZapInjectFailure = $true
    function Copy-Item {
        param([Parameter(Position=0)]$LiteralPath,[Parameter(Position=1)]$Destination,[switch]$Force)
        if ($global:BomZapInjectFailure -and $LiteralPath -match '\\stage\\service\.bat$') {
            $global:BomZapInjectFailure = $false
            throw 'Simulated copy failure'
        }
        Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
    }
    $global:LASTEXITCODE = 0
    & (Join-Path $install 'utils\BomZAP-update.ps1')
    if ($global:LASTEXITCODE -ne 1 -or $global:BomZapInjectFailure) { throw 'Injected failure was not detected.' }
    $global:LASTEXITCODE = 0
    if ((Get-Content (Join-Path $install '.bomzap-version') -Raw).Trim() -ne '1.1.0') { throw 'Previous version was not restored.' }
    if ((Get-Service 'zapret').Status -ne 'Running') { throw 'Previous service was not restarted after failure.' }
    if (Test-Path (Join-Path $env:ProgramData 'BomZAP\update\journal.json')) { throw 'Journal remains after rollback.' }
    Write-Host 'Simulated update, version check, settings and personal list passed.'
} finally {
    if ($createdService) {
        Stop-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
        & sc.exe delete zapret | Out-Null
    }
    Unregister-ScheduledTask -TaskName 'BomZAP Auto Update' -Confirm:$false -ErrorAction SilentlyContinue
    $env:ProgramData=$oldProgramData
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
