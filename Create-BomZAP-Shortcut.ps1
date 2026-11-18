$root = $PSScriptRoot
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'BomZAP.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "$env:SystemRoot\System32\cmd.exe"
$shortcut.Arguments = '/c ""' + (Join-Path $root 'service.bat') + '""'
$shortcut.WorkingDirectory = $root
$shortcut.IconLocation = (Join-Path $root 'BomZAP.ico') + ',0'
$shortcut.Description = 'BomZAP'
$shortcut.Save()
Write-Host "Created shortcut: $shortcutPath"
