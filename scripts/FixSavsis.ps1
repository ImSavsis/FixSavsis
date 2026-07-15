param(
    [switch]$ForceCycle
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Root       = Split-Path -Parent $PSScriptRoot
$BinDir     = Join-Path $Root 'engine\bin'
$Ultimate   = Join-Path $Root 'strategies\ultimate'
$Combined   = Join-Path $Root 'strategies\combined'
$Fallback   = Join-Path $Root 'strategies'
$DataDir    = Join-Path $env:LOCALAPPDATA 'FixSavsis'
$LogDir     = Join-Path $DataDir 'logs'
$StatePath  = Join-Path $DataDir 'state.json'
$UpdateUrl  = 'https://fix.savsis.xyz/api/lists.json'

New-Item -ItemType Directory -Force -Path $DataDir, $LogDir | Out-Null
. (Join-Path $PSScriptRoot 'clean-cache.ps1')

function Write-Log {
    param([string]$Msg)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
    $line | Tee-Object -FilePath (Join-Path $LogDir "fixsavsis.log") -Append | Out-Null
}

function Test-Assert-Admin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Not elevated, relaunching as admin..."
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', "`"$PSCommandPath`""
        )
        exit
    }
}

function Test-TlsHost {
    param([string]$HostName, [int]$Port = 443, [int]$TimeoutMs = 3000)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $tcp.Close(); return $false }
        $tcp.EndConnect($iar)
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, ({ $true }))
        $ssl.AuthenticateAsClient($HostName)
        $ok = $ssl.IsAuthenticated
        $ssl.Close(); $tcp.Close()
        return $ok
    } catch {
        return $false
    }
}

function Test-Connectivity {
    $discordOk  = (Test-TlsHost -HostName 'discord.com') -or (Test-TlsHost -HostName 'gateway.discord.gg')
    $telegramOk = (Test-TlsHost -HostName 'web.telegram.org') -or (Test-TlsHost -HostName 'telegram.org')
    [pscustomobject]@{ Discord = $discordOk; Telegram = $telegramOk; Score = [int]$discordOk + [int]$telegramOk }
}

function Stop-Winws {
    Get-Process -Name 'winws' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

function Start-Strategy {
    param([string]$BatPath)
    Stop-Winws
    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$BatPath`"" -WindowStyle Hidden
    Start-Sleep -Seconds 3
}

function Get-CandidateList {
    $ordered = @()
    13..2 | ForEach-Object {
        $f = Join-Path $Ultimate "UltimateFix (ALT v$_).bat"
        if (Test-Path $f) { $ordered += $f }
    }
    $extraUltimate = @('UltimateFix (ALT).bat', 'UltimateFix (Beeline, Rostelekom, Infolink).bat', 'UltimateFix (MGTS).bat', 'UltimateFix.bat')
    foreach ($name in $extraUltimate) {
        $f = Join-Path $Ultimate $name
        if (Test-Path $f) { $ordered += $f }
    }
    13..2 | ForEach-Object {
        $f = Join-Path $Combined "CombinedFix (ALT v$_).bat"
        if (Test-Path $f) { $ordered += $f }
    }
    $extraCombined = @('CombinedFix (ALT).bat', 'CombinedFix (Beeline, Rostelekom, Infolink).bat', 'CombinedFix (MGTS).bat', 'CombinedFix.bat')
    foreach ($name in $extraCombined) {
        $f = Join-Path $Combined $name
        if (Test-Path $f) { $ordered += $f }
    }
    return $ordered
}

function Save-State {
    param([string]$Strategy, [int]$Score)
    @{ strategy = $Strategy; score = $Score; savedAt = (Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8
}

function Get-State {
    if (Test-Path $StatePath) {
        try { return Get-Content $StatePath -Raw | ConvertFrom-Json } catch { return $null }
    }
    return $null
}

function Invoke-StrategyCycle {
    Write-Log "Starting strategy cycle..."
    $state = Get-State
    $candidates = Get-CandidateList

    if ($state -and $state.strategy -and (Test-Path $state.strategy)) {
        $candidates = @($state.strategy) + ($candidates | Where-Object { $_ -ne $state.strategy })
    }

    $best = $null
    $bestScore = -1
    foreach ($bat in $candidates) {
        $name = Split-Path -Leaf $bat
        Write-Log "Trying strategy: $name"
        Start-Strategy -BatPath $bat
        $result = Test-Connectivity
        Write-Log ("  discord=$($result.Discord) telegram=$($result.Telegram)")
        if ($result.Score -gt $bestScore) {
            $best = $bat; $bestScore = $result.Score
        }
        if ($result.Score -eq 2) {
            Write-Log "Strategy '$name' works for both Discord and Telegram. Locking it in."
            Save-State -Strategy $bat -Score 2
            return [pscustomobject]@{ Strategy = $bat; Score = 2 }
        }
        Stop-Winws
    }

    if ($best) {
        Write-Log "No strategy covered both fully. Falling back to best partial: $(Split-Path -Leaf $best) (score=$bestScore)"
        Start-Strategy -BatPath $best
        Save-State -Strategy $best -Score $bestScore
        return [pscustomobject]@{ Strategy = $best; Score = $bestScore }
    }

    Write-Log "No strategy produced any working connection."
    return [pscustomobject]@{ Strategy = $null; Score = 0 }
}

function Update-ListsFromServer {
    try {
        $resp = Invoke-RestMethod -Uri $UpdateUrl -TimeoutSec 5
        if ($resp.lists) {
            foreach ($item in $resp.lists) {
                $dest = Join-Path $Root ('engine\lists\' + $item.name)
                [System.IO.File]::WriteAllText($dest, $item.content)
            }
            Write-Log "Lists updated from fix.savsis.xyz"
        }
    } catch {
        Write-Log "Update check skipped (server unreachable): $($_.Exception.Message)"
    }
}

Test-Assert-Admin
Write-Log "=== FixSavsis starting ==="
Write-Output "Очистка кэша Discord/Telegram..."
Clear-DiscordCache | ForEach-Object { Write-Log $_ }
Clear-TelegramCache | ForEach-Object { Write-Log $_ }
Update-ListsFromServer

$state = Get-State
$current = $null
if (-not $ForceCycle -and $state -and $state.strategy -and (Test-Path $state.strategy)) {
    Write-Log "Trying last-known-good strategy fast path: $($state.strategy)"
    Start-Strategy -BatPath $state.strategy
    $result = Test-Connectivity
    if ($result.Score -ge 1) {
        Write-Log "Fast path OK (score=$($result.Score))"
        $current = [pscustomobject]@{ Strategy = $state.strategy; Score = $result.Score }
    }
}
if (-not $current) {
    $current = Invoke-StrategyCycle
}

$icon = [System.Drawing.SystemIcons]::Shield
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = $icon
$notifyIcon.Visible = $true

function Update-TrayText {
    param($state)
    if ($state.Strategy) {
        $name = Split-Path -Leaf $state.Strategy
        $statusWord = if ($state.Score -eq 2) { 'OK (Discord+Telegram)' } else { 'частично' }
        $notifyIcon.Text = "FixSavsis: $statusWord`n$name"
    } else {
        $notifyIcon.Text = "FixSavsis: не пробилось ни одной стратегией"
    }
}
Update-TrayText $current

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$itemRetest = $menu.Items.Add('Перепроверить / пересканировать стратегии')
$itemRetest.add_Click({
    $notifyIcon.ShowBalloonTip(2000, 'FixSavsis', 'Пересканирую стратегии...', [System.Windows.Forms.ToolTipIcon]::Info)
    $script:current = Invoke-StrategyCycle
    Update-TrayText $script:current
})

$itemClean = $menu.Items.Add('Очистить кэш Discord/Telegram сейчас')
$itemClean.add_Click({
    Clear-DiscordCache | ForEach-Object { Write-Log $_ }
    Clear-TelegramCache | ForEach-Object { Write-Log $_ }
    $notifyIcon.ShowBalloonTip(2000, 'FixSavsis', 'Кэш очищен.', [System.Windows.Forms.ToolTipIcon]::Info)
})

$itemLogs = $menu.Items.Add('Открыть логи')
$itemLogs.add_Click({ Start-Process explorer.exe $LogDir })

$itemExit = $menu.Items.Add('Выход (остановить обход)')
$itemExit.add_Click({
    Stop-Winws
    $notifyIcon.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

$notifyIcon.ContextMenuStrip = $menu

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 180000
$timer.add_Tick({
    $r = Test-Connectivity
    if ($r.Score -eq 0) {
        Write-Log "Health check failed, re-cycling strategies..."
        $script:current = Invoke-StrategyCycle
        Update-TrayText $script:current
    }
})
$timer.Start()

Write-Log "Tray running. Current strategy score: $($current.Score)"
[System.Windows.Forms.Application]::Run()
