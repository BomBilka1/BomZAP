$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sourcePath = Join-Path $root 'utils\BomZAP-auto.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$errors)
if ($errors.Count) { $errors | ForEach-Object { Write-Error $_ }; exit 1 }
$defs = $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)
foreach ($name in @('Set-ServiceBinaryPath','Restore-OldService','Wait-ServiceState')) {
    $definition = $defs | Where-Object Name -eq $name
    if (-not $definition) { throw "Missing $name" }
    Invoke-Expression $definition.Extent.Text
}
$serviceName = 'BomZapAutoTest'
function Get-ServiceInfo { Get-CimInstance Win32_Service -Filter "Name='BomZapAutoTest'" }
if (Get-Service $serviceName -ErrorAction SilentlyContinue) { throw 'Test service already exists.' }
$tempRoot = Join-Path $env:TEMP ('bomzap-service-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tempRoot | Out-Null
$created=$false
try {
    $source = @'
using System.ServiceProcess;
public class BomZapAutoTestService : ServiceBase {
    protected override void OnStart(string[] args) { }
    protected override void OnStop() { }
    public static void Main() { Run(new BomZapAutoTestService()); }
}
'@
    $exe=Join-Path $tempRoot 'service.exe'
    Add-Type -TypeDefinition $source -ReferencedAssemblies 'System.ServiceProcess.dll' -OutputAssembly $exe -OutputType ConsoleApplication
    $oldPath='"' + $exe + '" --old'
    New-Service -Name $serviceName -BinaryPathName $oldPath -StartupType Manual | Out-Null
    $created=$true
    Start-Service $serviceName
    Wait-ServiceState $serviceName 'Running'
    $old=Get-ServiceInfo
    Stop-Service $serviceName
    Wait-ServiceState $serviceName 'Stopped'
    # Nothing was reconfigured: recovery must only restart, not change config.
    Restore-OldService $old $true $false
    if ((Get-ServiceInfo).PathName -ne $old.PathName -or (Get-Service $serviceName).Status -ne 'Running') { throw 'Recovery without reconfiguration failed.' }
    Stop-Service $serviceName
    Wait-ServiceState $serviceName 'Stopped'
    $longPath='"' + $exe + '" ' + ((1..350 | ForEach-Object { '--test=123456789' }) -join ' ')
    if ($longPath.Length -lt 3000) { throw 'Test command is not long enough.' }
    Set-ServiceBinaryPath $longPath 'Automatic'
    if ((Get-ServiceInfo).PathName -ne $longPath) { throw 'Long command was not stored intact.' }
    Start-Service $serviceName
    Wait-ServiceState $serviceName 'Running'
    Restore-OldService $old $true $true
    $restored=Get-ServiceInfo
    if ($restored.PathName -ne $old.PathName -or $restored.StartMode -ne $old.StartMode -or (Get-Service $serviceName).Status -ne 'Running') { throw 'Recovery after reconfiguration failed.' }
    Write-Host 'Long service command and both recovery paths passed.'
} finally {
    if ($created) { Stop-Service $serviceName -Force -ErrorAction SilentlyContinue; & sc.exe delete $serviceName | Out-Null }
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
