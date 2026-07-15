$ErrorActionPreference = 'Stop'
$TaskName = 'FixSavsis-AutoStart'
$ScriptPath = Join-Path $PSScriptRoot 'FixSavsis.ps1'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Output "Task '$TaskName' registered: launches FixSavsis.ps1 hidden+elevated at logon."
Write-Output "Starting it now for this session..."
Start-ScheduledTask -TaskName $TaskName
