$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scriptPath = Join-Path $root 'utils\BomZAP-auto.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { $errors | ForEach-Object { Write-Error $_ }; exit 1 }
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($name in @('Read-Strategy', 'Add-PersonalProfile')) {
    $f = $functions | Where-Object Name -eq $name
    if (-not $f) { throw "Missing function $name" }
    Invoke-Expression $f.Extent.Text
}
$personal = Read-Strategy (Get-Item (Join-Path $root 'general (BomZAP PERSONAL).bat'))
if ($personal -notmatch '(--filter-tcp=80,443\s+--hostlist="[^"]*list-bomzap-personal\.txt".*?--new)(?:\s|$)') { throw 'Missing personal rule' }
$rule = $matches[1]
$count = 0
Get-ChildItem $root -Filter 'general*.bat' | ForEach-Object {
    $a = Read-Strategy $_
    $a = Add-PersonalProfile $a $rule
    if ($a -notmatch 'list-bomzap-personal\.txt' -or $a -match '%[^%]+%') { throw "Invalid strategy $($_.Name)" }
    if ($a -notmatch '--wf-tcp=' -or $a -notmatch '--wf-udp=') { throw "Missing capture filter in $($_.Name)" }
    $script:count++
}
if ($count -lt 2) { throw 'Expected multiple strategies' }
Write-Host "Verified syntax and $count strategy argument sets."
