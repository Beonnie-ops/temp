#Requires -Version 5.1
<#
.SYNOPSIS
    Показывает, что занимает место на дисках сервера.

.DESCRIPTION
    Скрипт печатает три блока:
      1) свободное/занятое место по каждому диску;
      2) самые тяжёлые каталоги первого уровня (глубину задаёт -Depth);
      3) типовых «пожирателей» места на Windows-сервере — Windows\Temp,
         SoftwareDistribution\Download, Installer, WinSxS, WER, корзины,
         пользовательские Temp, pagefile.sys / hiberfil.sys.

    Подсчёт идёт обычным перебором файлов, на большом томе это занимает
    заметное время (десятки минут на диске с миллионами файлов). Если нужен
    мгновенный результат — используйте WizTree, она читает MFT напрямую.

.PARAMETER Path
    Что анализировать. По умолчанию — все локальные диски.

.PARAMETER Top
    Сколько самых больших каталогов показывать. По умолчанию 15.

.PARAMETER Depth
    Глубина, на которой считаются каталоги: 1 — только `C:\Windows`,
    2 — ещё и `C:\Windows\WinSxS` и т. д. По умолчанию 1.

.PARAMETER MinSizeMB
    Не показывать каталоги меньше указанного размера. По умолчанию 100 МБ.

.PARAMETER IncludeFiles
    Дополнительно вывести самые большие отдельные файлы.

.PARAMETER SkipKnownSuspects
    Не проверять типовых «пожирателей» места.

.EXAMPLE
    .\Get-DiskUsage.ps1
    Отчёт по всем дискам.

.EXAMPLE
    .\Get-DiskUsage.ps1 -Path C:\ -Depth 2 -Top 30 -IncludeFiles
    Подробный отчёт по системному диску с самыми большими файлами.

.EXAMPLE
    .\Get-DiskUsage.ps1 >> C:\Scripts\diskusage.log
    Отчёт в файл (запускать по расписанию).

.NOTES
    Файл обязан храниться в кодировке UTF-8 с BOM: Windows PowerShell 5.1
    читает .ps1 без BOM как ANSI и ломается на русском тексте.
    Запускать от имени администратора, иначе часть каталогов будет пропущена.
#>
[CmdletBinding()]
param(
    [string[]]$Path,
    [ValidateRange(1, 500)][int]$Top = 15,
    [ValidateRange(1, 10)][int]$Depth = 1,
    [ValidateRange(0, 1048576)][double]$MinSizeMB = 100,
    [switch]$IncludeFiles,
    [switch]$SkipKnownSuspects
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$onWindows = $true
$platformVar = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
if ($platformVar) { $onWindows = [bool]$platformVar.Value }

function Format-FileCount {
    param([int]$Count)
    $tail = $Count % 100
    if ($tail -ge 11 -and $tail -le 14) { return ('{0} файлов' -f $Count) }
    switch ($Count % 10) {
        1 { '{0} файл' -f $Count }
        2 { '{0} файла' -f $Count }
        3 { '{0} файла' -f $Count }
        4 { '{0} файла' -f $Count }
        default { '{0} файлов' -f $Count }
    }
}

function Format-Size {
    param([double]$Bytes)
    $units = 'B', 'KiB', 'MiB', 'GiB', 'TiB'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt ($units.Count - 1)) { $Bytes /= 1024; $i++ }
    if ($i -eq 0) { '{0:N0} {1}' -f $Bytes, $units[$i] } else { '{0:N1} {1}' -f $Bytes, $units[$i] }
}

# Размер каталога = сумма длин всех файлов внутри. Точки повторной обработки
# (симлинки, junction) не разворачиваем, иначе можно уйти в бесконечный цикл
# и посчитать одно и то же дважды.
function Measure-Folder {
    param([string]$LiteralPath)

    $bytes = [long]0
    $files = 0
    $items = Get-ChildItem -LiteralPath $LiteralPath -Recurse -Force -File `
        -Attributes !ReparsePoint -ErrorAction SilentlyContinue
    foreach ($item in $items) {
        $bytes += $item.Length
        $files++
    }
    [pscustomobject]@{ Bytes = $bytes; Files = $files }
}

function Get-TargetPath {
    param([string[]]$Requested, [bool]$OnWindows)

    if ($Requested) {
        foreach ($p in $Requested) {
            if (Test-Path -LiteralPath $p) { (Resolve-Path -LiteralPath $p).Path }
            else { Write-Warning ('путь не найден: {0}' -f $p) }
        }
        return
    }

    if ($OnWindows) {
        # DriveType=3 — локальный диск, сетевые и съёмные не трогаем.
        Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction SilentlyContinue |
            ForEach-Object { $_.DeviceID + '\' }
    }
    else {
        '/'
    }
}

function Write-VolumeSummary {
    param([bool]$OnWindows)

    Write-Output '=== Диски ==='
    if (-not $OnWindows) {
        Write-Output 'Сводка по томам доступна только на Windows, используйте df -h.'
        Write-Output ''
        return
    }

    $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction SilentlyContinue
    foreach ($disk in $disks) {
        $total = [double]$disk.Size
        $free = [double]$disk.FreeSpace
        $percent = 0
        if ($total -gt 0) { $percent = 100 * ($total - $free) / $total }
        Write-Output ('{0} {1} — занято {2} из {3} ({4:N1} %), свободно {5}' -f `
                $disk.DeviceID, $disk.VolumeName, (Format-Size ($total - $free)),
            (Format-Size $total), $percent, (Format-Size $free))
    }
    Write-Output ''
}

function Write-HeaviestFolder {
    param([string]$Root, [int]$Levels, [int]$Count, [double]$MinMB)

    Write-Output ('=== Самые большие каталоги в {0} (глубина {1}) ===' -f $Root, $Levels)

    $dirs = Get-ChildItem -LiteralPath $Root -Directory -Recurse -Depth ($Levels - 1) -Force `
        -Attributes !ReparsePoint -ErrorAction SilentlyContinue
    $results = @()
    foreach ($dir in $dirs) {
        $measured = Measure-Folder -LiteralPath $dir.FullName
        $results += [pscustomobject]@{
            Path  = $dir.FullName
            Bytes = $measured.Bytes
            Files = $measured.Files
        }
    }

    # Файлы, лежащие прямо в корне, ни в один подкаталог не попадают,
    # поэтому добавляем их отдельной строкой в общий рейтинг.
    $rootFiles = @(Get-ChildItem -LiteralPath $Root -File -Force -ErrorAction SilentlyContinue)
    if ($rootFiles.Count -gt 0) {
        $results += [pscustomobject]@{
            Path  = $Root + '  (файлы в корне)'
            Bytes = [long](($rootFiles | Measure-Object -Property Length -Sum).Sum)
            Files = $rootFiles.Count
        }
    }

    $limit = [long]($MinMB * 1MB)
    $shown = @($results | Where-Object { $_.Bytes -ge $limit } | Sort-Object Bytes -Descending | Select-Object -First $Count)
    if ($shown.Count -eq 0) {
        Write-Output ('Каталогов больше {0} МБ не найдено.' -f $MinMB)
    }
    foreach ($row in $shown) {
        Write-Output ('{0,12}  {1,14}  {2}' -f (Format-Size $row.Bytes), (Format-FileCount $row.Files), $row.Path)
    }
    Write-Output ''
}

function Write-LargestFile {
    param([string]$Root, [int]$Count)

    Write-Output ('=== Самые большие файлы в {0} ===' -f $Root)
    $files = Get-ChildItem -LiteralPath $Root -File -Recurse -Force -Attributes !ReparsePoint `
        -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending | Select-Object -First $Count
    foreach ($file in $files) {
        Write-Output ('{0,12}  {1:yyyy-MM-dd}  {2}' -f (Format-Size $file.Length), $file.LastWriteTime, $file.FullName)
    }
    Write-Output ''
}

function Write-KnownSuspect {
    param([string]$Root)

    $folders = @(
        'Windows\Temp',
        'Windows\SoftwareDistribution\Download',
        'Windows\Installer',
        'Windows\WinSxS',
        'Windows\Logs',
        'Windows\Minidump',
        'Windows\LiveKernelReports',
        'ProgramData\Microsoft\Windows\WER',
        'ProgramData\Package Cache',
        'inetpub\logs',
        '$Recycle.Bin',
        'Users\*\AppData\Local\Temp',
        'Users\*\AppData\Local\CrashDumps',
        'Users\*\AppData\Local\Microsoft\Windows\INetCache',
        'Users\*\AppData\Local\Microsoft\Outlook'
    )
    $files = 'pagefile.sys', 'hiberfil.sys', 'swapfile.sys'

    Write-Output ('=== Типовые пожиратели места в {0} ===' -f $Root)
    $found = $false

    foreach ($rel in $folders) {
        $full = Join-Path $Root $rel
        if ($rel.Contains('*')) {
            $expanded = @(Resolve-Path -Path $full -ErrorAction SilentlyContinue)
            if ($expanded.Count -eq 0) { continue }
            $bytes = [long]0
            $count = 0
            foreach ($m in $expanded) {
                $measured = Measure-Folder -LiteralPath $m.Path
                $bytes += $measured.Bytes
                $count += $measured.Files
            }
            $found = $true
            Write-Output ('{0,12}  {1,14}  {2} (профилей: {3})' -f `
                (Format-Size $bytes), (Format-FileCount $count), $full, $expanded.Count)
        }
        else {
            if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
            $measured = Measure-Folder -LiteralPath $full
            $found = $true
            Write-Output ('{0,12}  {1,14}  {2}' -f (Format-Size $measured.Bytes), (Format-FileCount $measured.Files), $full)
        }
    }

    foreach ($name in $files) {
        $full = Join-Path $Root $name
        $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
        if ($item) {
            $found = $true
            Write-Output ('{0,12}  {1,14}  {2}' -f (Format-Size $item.Length), '', $full)
        }
    }

    if (-not $found) { Write-Output 'Ничего из типового списка не найдено.' }
    Write-Output ''
}

Write-VolumeSummary -OnWindows $onWindows

foreach ($root in Get-TargetPath -Requested $Path -OnWindows $onWindows) {
    Write-HeaviestFolder -Root $root -Levels $Depth -Count $Top -MinMB $MinSizeMB
    if ($IncludeFiles) { Write-LargestFile -Root $root -Count $Top }
    if (-not $SkipKnownSuspects -and $onWindows) { Write-KnownSuspect -Root $root }
}

if ($onWindows) {
    Write-Output '=== Что ещё стоит проверить вручную ==='
    Write-Output 'Теневые копии:        vssadmin list shadowstorage'
    Write-Output 'Хранилище компонентов: Dism /Online /Cleanup-Image /AnalyzeComponentStore'
    Write-Output 'Очистка обновлений:    Dism /Online /Cleanup-Image /StartComponentCleanup'
    Write-Output 'Журналы событий:       Get-WinEvent -ListLog * | Sort-Object FileSize -Descending | Select-Object -First 10 LogName, FileSize'
}
