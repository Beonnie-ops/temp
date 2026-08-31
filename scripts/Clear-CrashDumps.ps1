<#
.SYNOPSIS
    Очищает папки аварийных дампов (CrashDumps / CrushDumps) у всех пользователей сервера.

.DESCRIPTION
    Скрипт перебирает профили пользователей (из реестра ProfileList, поэтому
    находит профили и вне C:\Users) и очищает в каждом из них папки с дампами:
        <Профиль>\AppData\Local\CrashDumps   — стандартное место WER
        <Профиль>\CrashDumps
    Сами папки по умолчанию остаются на месте, удаляется только содержимое.

    Запускать нужно от имени администратора, иначе чужие профили будут пропущены.

.PARAMETER DirName
    Имена искомых папок. По умолчанию CrashDumps и CrushDumps.

.PARAMETER OlderThanDays
    Удалять только файлы, изменённые более чем N суток назад. 0 — удалять всё.

.PARAMETER MaxDepth
    Глубина поиска папок внутри профиля. По умолчанию 3 (хватает для AppData\Local).

.PARAMETER RemoveDir
    Удалять и саму папку, а не только её содержимое.

.PARAMETER IncludeSystemProfiles
    Обрабатывать также системные профили (LocalSystem, LocalService, NetworkService).

.PARAMETER ProfilePath
    Явный список каталогов профилей вместо чтения реестра. Полезно для профилей
    в нестандартном месте (например, на файловой шаре) и для проверки скрипта.

.EXAMPLE
    .\Clear-CrashDumps.ps1 -WhatIf
    Показать, что будет удалено, ничего не удаляя.

.EXAMPLE
    .\Clear-CrashDumps.ps1 -OlderThanDays 7
    Удалить дампы старше семи суток у всех пользователей.

.NOTES
    Файл обязан храниться в кодировке UTF-8 с BOM. Windows PowerShell 5.1 читает
    .ps1 без BOM как ANSI (cp1251), русский текст рассыпается, и разбор падает с
    ошибкой вида «Непредвиденная лексема ")"». Если пересохраняете файл вручную,
    выбирайте «UTF-8 with BOM» либо «UTF-16 LE».
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]]$DirName = @('CrashDumps', 'CrushDumps'),
    [ValidateRange(0, 3650)][int]$OlderThanDays = 0,
    [ValidateRange(1, 10)][int]$MaxDepth = 3,
    [switch]$RemoveDir,
    [switch]$IncludeSystemProfiles,
    [string[]]$ProfilePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Чтобы русский текст в консоли не превращался в кашу (актуально для PowerShell 5.1).
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }

function Format-Size {
    param([double]$Bytes)
    $units = 'B', 'KiB', 'MiB', 'GiB', 'TiB'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt ($units.Count - 1)) { $Bytes /= 1024; $i++ }
    if ($i -eq 0) { '{0:N0} {1}' -f $Bytes, $units[$i] } else { '{0:N1} {1}' -f $Bytes, $units[$i] }
}

function Get-UserProfilePath {
    [CmdletBinding()]
    param([switch]$IncludeSystem)

    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    foreach ($item in Get-ChildItem -Path $key -ErrorAction SilentlyContinue) {
        $sid = Split-Path $item.Name -Leaf
        # S-1-5-18/19/20 — системные учётные записи.
        if (-not $IncludeSystem -and $sid -match '^S-1-5-(18|19|20)$') { continue }

        $props = Get-ItemProperty -Path $item.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        $path = $props.ProfileImagePath
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $path = [Environment]::ExpandEnvironmentVariables($path)
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }

        try {
            $name = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate(
                [System.Security.Principal.NTAccount]).Value
        }
        catch {
            $name = Split-Path $path -Leaf
        }

        [pscustomobject]@{ User = $name; Profile = $path }
    }
}

# $IsWindows появился только в PowerShell 6, в 5.1 переменной нет вовсе.
$onWindows = $true
$platformVar = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
if ($platformVar) { $onWindows = [bool]$platformVar.Value }

if ($onWindows) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Warning 'Скрипт запущен без прав администратора: часть профилей будет недоступна.'
    }
}

$profiles = if ($ProfilePath) {
    foreach ($p in $ProfilePath) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            [pscustomobject]@{ User = (Split-Path $p -Leaf); Profile = (Resolve-Path -LiteralPath $p).Path }
        }
        else { Write-Warning ('профиль не найден: {0}' -f $p) }
    }
}
else {
    Get-UserProfilePath -IncludeSystem:$IncludeSystemProfiles
}

$cutoff = if ($OlderThanDays -gt 0) { (Get-Date).AddDays(-$OlderThanDays) } else { [datetime]::MaxValue }
$totalFiles = 0
$totalBytes = [long]0
$totalDirs = 0

foreach ($userProfile in $profiles) {
    $targets = @(Get-ChildItem -LiteralPath $userProfile.Profile -Directory -Recurse -Depth ($MaxDepth - 1) `
            -Force -ErrorAction SilentlyContinue |
        Where-Object { $DirName -contains $_.Name -and -not $_.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) })

    foreach ($target in $targets) {
        $files = @(Get-ChildItem -LiteralPath $target.FullName -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $OlderThanDays -eq 0 -or $_.LastWriteTime -lt $cutoff })

        $bytes = [long]0
        if ($files.Count -gt 0) {
            $bytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
        }

        $totalDirs++
        $totalFiles += $files.Count
        $totalBytes += $bytes

        Write-Host ('{0}: {1} — файлов: {2}, объём: {3}' -f `
                $userProfile.User, $target.FullName, $files.Count, (Format-Size $bytes))

        foreach ($file in $files) {
            if ($PSCmdlet.ShouldProcess($file.FullName, 'Удалить файл дампа')) {
                try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop }
                catch { Write-Warning ('не удалось удалить {0}: {1}' -f $file.FullName, $_.Exception.Message) }
            }
        }

        # Пустые подкаталоги убираем снизу вверх.
        Get-ChildItem -LiteralPath $target.FullName -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object {
                if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue)) {
                    if ($PSCmdlet.ShouldProcess($_.FullName, 'Удалить пустой каталог')) {
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    }
                }
            }

        if ($RemoveDir -and $PSCmdlet.ShouldProcess($target.FullName, 'Удалить каталог дампов')) {
            Remove-Item -LiteralPath $target.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ('Итого: каталогов {0}, файлов {1}, объём {2}' -f `
        $totalDirs, $totalFiles, (Format-Size $totalBytes))
