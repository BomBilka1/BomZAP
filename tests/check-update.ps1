$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scriptPath = Join-Path $repositoryRoot 'utils\BomZAP-update.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { $errors | ForEach-Object { Write-Error $_ }; exit 1 }
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($name in @('Is-Protected', 'Restore-Update')) {
    $f = $functions | Where-Object Name -eq $name
    if (-not $f) { throw "Missing function $name" }
    Invoke-Expression $f.Extent.Text
}
foreach ($name in @('lists\ipset-all.txt', 'lists\list-bomzap-personal.txt', 'lists\list-general-user.txt', 'utils\game_filter.enabled', 'bin\ACTIVE_GAME_UDP.bin')) {
    if (-not (Is-Protected $name)) { throw "Not protected: $name" }
}
if (Is-Protected 'utils\BomZAP-auto.ps1') { throw 'Program code should update.' }
$work = Join-Path $env:TEMP ('bomzap-test-' + [guid]::NewGuid().ToString('N'))
$root = Join-Path $work 'root'; $backup = Join-Path $work 'backup'; $journalPath = Join-Path $work 'journal.json'
New-Item -ItemType Directory -Force -Path $root,$backup | Out-Null
try {
    function Stop-OwnService { }
    function Get-OwnService { return $null }
    [IO.File]::WriteAllText((Join-Path $root 'old.txt'), 'changed')
    [IO.File]::WriteAllText((Join-Path $root 'new.txt'), 'new')
    [IO.File]::WriteAllText((Join-Path $backup 'old.txt'), 'original')
    [IO.File]::WriteAllText($journalPath, '{}')
    $journal = [PSCustomObject]@{ MutationStarted=$true; WasRunning=$false; Files=@([PSCustomObject]@{Path='old.txt';Existed=$true},[PSCustomObject]@{Path='new.txt';Existed=$false}) }
    Restore-Update $journal
    if ([IO.File]::ReadAllText((Join-Path $root 'old.txt')) -ne 'original') { throw 'Original was not restored' }
    if ((Test-Path (Join-Path $root 'new.txt')) -or (Test-Path $journalPath)) { throw 'New file or journal was not removed' }
    [IO.File]::WriteAllText($journalPath, '{}')
    Restore-Update ([PSCustomObject]@{MutationStarted=$false;WasRunning=$false;Files=@()})
    if (Test-Path $journalPath) { throw 'Unstarted transaction journal was not removed' }
    Write-Host 'Updater syntax, protected settings and rollback passed.'
} finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
