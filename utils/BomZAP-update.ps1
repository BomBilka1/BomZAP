param([switch]$Register, [switch]$Silent)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$versionPath = Join-Path $root '.bomzap-version'
$taskName = 'BomZAP Auto Update'
$work = Join-Path $env:ProgramData 'BomZAP\update'
$journalPath = Join-Path $work 'journal.json'
$backup = Join-Path $work 'backup'
$stage = Join-Path $work 'stage'
$serviceName = 'zapret'

function Ensure-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator rights are required.'
    }
}
function Get-OwnService {
    $s = Get-CimInstance Win32_Service -Filter "Name='zapret'" -ErrorAction Stop
    if ($s) {
        $exe = Join-Path $root 'bin\winws.exe'
        if (-not ($s.PathName.StartsWith('"' + $exe + '"', [StringComparison]::OrdinalIgnoreCase))) {
            throw 'The zapret service belongs to another folder. Update that installation instead.'
        }
    }
    return $s
}
function Wait-ServiceStatus($desired) {
    (Get-Service -Name $serviceName).WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::$desired, [TimeSpan]::FromSeconds(25))
}
function Stop-OwnService {
    $s = Get-OwnService
    if ($s -and $s.State -eq 'Running') { Stop-Service $serviceName; Wait-ServiceStatus 'Stopped' }
    elseif ($s -and $s.State -ne 'Stopped') { throw 'The service is changing state. Try again later.' }
    $ownExe = Join-Path $root 'bin\winws.exe'
    $running = @(Get-CimInstance Win32_Process -Filter "Name='winws.exe'" | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.Equals($ownExe,[StringComparison]::OrdinalIgnoreCase) })
    if ($running.Count -gt 0) { throw 'A manually started winws.exe is running. Stop it before updating.' }
}
function Restore-Update($journal) {
    if (-not $journal.MutationStarted) {
        $s = Get-OwnService
        if ($journal.WasRunning -and $s -and $s.State -ne 'Running') { Start-Service $serviceName; Wait-ServiceStatus 'Running' }
        Remove-Item -LiteralPath $journalPath -Force
        return
    }
    Stop-OwnService
    foreach ($entry in @($journal.Files)) {
        $target = Join-Path $root $entry.Path
        $saved = Join-Path $backup $entry.Path
        if ($entry.Existed) {
            if (-not (Test-Path -LiteralPath $saved -PathType Leaf)) { throw "Backup missing: $($entry.Path)" }
            New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
            if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
                (Get-FileHash -LiteralPath $saved -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) {
                Copy-Item -LiteralPath $saved -Destination $target -Force
            }
        } elseif (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force }
    }
    if ($journal.WasRunning) { Start-Service $serviceName; Wait-ServiceStatus 'Running' }
    Remove-Item -LiteralPath $journalPath -Force
}
function Is-Protected($relative) {
    $p = $relative.Replace('/','\')
    if ($p -match '^lists\\(list-bomzap-personal\.txt|.*-user\.txt|ipset-all\.txt(?:\.backup)?)$') { return $true }
    if ($p -match '^utils\\(game_filter\.enabled|check_updates\.enabled|targets\.txt)$') { return $true }
    if ($p -match '^bin\\ACTIVE_.*\.bin$') { return $true }
    return $false
}
try {
    Ensure-Admin
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    if (Test-Path -LiteralPath $journalPath) {
        $pending = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
        Restore-Update $pending
        Write-Host 'Previous interrupted update restored.'
    }
    if ($Register) {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $script = Join-Path $root 'utils\BomZAP-update.ps1'
        $action = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $script + '" -Silent')
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        Write-Host 'Automatic update check enabled at Windows sign-in.'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent'='BomZAP-Updater'; 'Accept'='application/vnd.github+json' }
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/BomBilka1/BomZAP/releases/latest' -Headers $headers -TimeoutSec 30
    if ($release.draft -or $release.prerelease -or $release.tag_name -notmatch '^v(\d+\.\d+\.\d+)$') { throw 'The latest release has an unsupported version.' }
    $remoteVersion = [version]$matches[1]
    $installed = if (Test-Path -LiteralPath $versionPath) { [version]((Get-Content -LiteralPath $versionPath -Raw).Trim().TrimStart('v')) } else { [version]'0.0.0' }
    if ($remoteVersion -le $installed) { Write-Host "BomZAP is up to date ($installed)."; return }
    $assets = @($release.assets | Where-Object { $_.name -eq ('BomZAP-v' + $remoteVersion + '.zip') })
    if ($assets.Count -ne 1 -or $assets[0].digest -notmatch '^sha256:([0-9a-fA-F]{64})$') { throw 'Release archive or SHA-256 digest is missing.' }
    $expected = $matches[1].ToLowerInvariant()
    $url = [string]$assets[0].browser_download_url
    if (-not $url.StartsWith('https://github.com/BomBilka1/BomZAP/releases/download/',[StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected download address.' }
    $zipPath = Join-Path $work 'release.zip'
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -TimeoutSec 180
    if ((Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'Archive SHA-256 verification failed.' }
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    if (Test-Path $backup) { Remove-Item $backup -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $stage,$backup | Out-Null
    # Resolve short Windows paths (for example RUNNER~1) before deriving relative names.
    $stage = (Get-Item -LiteralPath $stage).FullName
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        if ($zip.Entries.Count -gt 3000) { throw 'Archive has too many entries.' }
        [long]$total = 0
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('\','/')
            if (-not $name.StartsWith('BomZAP/')) { throw 'Unexpected archive root.' }
            $rel = $name.Substring(7)
            if (-not $rel -or $name.EndsWith('/')) { continue }
            if ($rel -match '(^|/)\.\.(/|$)' -or $rel -match '[:*?]' -or $rel.StartsWith('/')) { throw 'Unsafe archive path.' }
            $total += $entry.Length
            if ($total -gt 200MB) { throw 'Archive is too large.' }
            if ($rel -match '^(\.github|tests)/' -or $rel -in @('.gitignore','.gitattributes')) { continue }
            $dest = Join-Path $stage ($rel.Replace('/','\'))
            $full = [IO.Path]::GetFullPath($dest)
            if (-not $full.StartsWith(([IO.Path]::GetFullPath($stage).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Archive path escapes staging folder.' }
            New-Item -ItemType Directory -Force -Path (Split-Path $full -Parent) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$full,$false)
        }
    } finally { $zip.Dispose() }
    $candidateVersion = Join-Path $stage '.bomzap-version'
    if (-not (Test-Path $candidateVersion) -or ([version]((Get-Content $candidateVersion -Raw).Trim()) -ne $remoteVersion)) { throw 'Archive version does not match release.' }
    foreach ($required in @('bin\winws.exe','utils\BomZAP-update.ps1','service.bat')) {
        if (-not (Test-Path (Join-Path $stage $required) -PathType Leaf)) { throw "Missing required file: $required" }
    }
    # Preserve personal domains while adding entries delivered in the release.
    $personal = 'lists\list-bomzap-personal.txt'
    $existing = Join-Path $root $personal
    $incoming = Join-Path $stage $personal
    if ((Test-Path $existing) -and (Test-Path $incoming)) {
        $merged = @(@(Get-Content $existing) + @(Get-Content $incoming) | Select-Object -Unique)
        [IO.File]::WriteAllLines($incoming,[string[]]$merged,(New-Object Text.UTF8Encoding($false)))
    }
    $files = @(Get-ChildItem -LiteralPath $stage -File -Recurse | ForEach-Object {
        $relative = $_.FullName.Substring($stage.TrimEnd('\').Length + 1)
        if (-not (Is-Protected $relative) -or $relative -eq $personal) {
            $target = Join-Path $root $relative
            $exists = Test-Path -LiteralPath $target -PathType Leaf
            if (-not $exists -or (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) {
                [PSCustomObject]@{ Path=$relative; Existed=$exists }
            }
        }
    })
    foreach ($entry in $files) {
        if ($entry.Existed) {
            $dest = Join-Path $backup $entry.Path
            New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
            Copy-Item -LiteralPath (Join-Path $root $entry.Path) -Destination $dest -Force
        }
    }
    $svc = Get-OwnService
    $wasRunning = [bool]($svc -and $svc.State -eq 'Running')
    $journal = [PSCustomObject]@{ WasRunning=$wasRunning; MutationStarted=$false; Files=$files }
    $journal | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $journalPath -Encoding UTF8
    try {
        Stop-OwnService
        $journal.MutationStarted = $true
        $journal | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $journalPath -Encoding UTF8
        foreach ($entry in $files) {
            $dest = Join-Path $root $entry.Path
            New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
            Copy-Item -LiteralPath (Join-Path $stage $entry.Path) -Destination $dest -Force
        }
        if ($wasRunning) { Start-Service $serviceName; Wait-ServiceStatus 'Running' }
        Remove-Item -LiteralPath $journalPath -Force
        Write-Host "Updated BomZAP to $remoteVersion."
    } catch {
        $failure = $_.Exception.Message
        try { Restore-Update $journal } catch { throw "Update failed: $failure. Restore failed: $($_.Exception.Message). Backups: $backup" }
        throw "Update failed; previous files restored: $failure"
    }
} catch {
    Write-Host "UPDATE ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
