function Clear-PathQuiet {
    param([string]$Path)
    if (Test-Path $Path) {
        try {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-Output "  cleared: $Path"
        } catch {
            Write-Output "  skipped (locked): $Path"
        }
    }
}

function Clear-DiscordCache {
    $roots = @(
        "$env:APPDATA\discord",
        "$env:APPDATA\discordcanary",
        "$env:APPDATA\discordptb"
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        Write-Output "Discord: $root"
        foreach ($sub in @("Cache", "Code Cache", "GPUCache", "DawnCache", "Local Storage\leveldb", "logs", "Session Storage")) {
            Clear-PathQuiet (Join-Path $root $sub)
        }
    }
}

function Clear-TelegramCache {
    $root = "$env:APPDATA\Telegram Desktop\tdata"
    if (-not (Test-Path $root)) { return }
    Write-Output "Telegram: $root"
    Get-ChildItem -Path $root -Directory -Filter "user_data*" -ErrorAction SilentlyContinue | ForEach-Object {
        Clear-PathQuiet (Join-Path $_.FullName "cache")
        Clear-PathQuiet (Join-Path $_.FullName "media_cache")
    }
    Clear-PathQuiet (Join-Path $root "emoji")
}

if ($MyInvocation.InvocationName -ne '.') {
    Write-Output "Cleaning Discord + Telegram cache..."
    Clear-DiscordCache
    Clear-TelegramCache
    Write-Output "Done."
}
