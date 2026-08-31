# Обслуживание дискового пространства на сервере

| Файл | Назначение | Где запускать |
| --- | --- | --- |
| `Get-DiskUsage.ps1` | отчёт «что занимает место» | Windows Server (PowerShell 5.1 или 7+) |
| `Clear-CrashDumps.ps1` | очистка папок с дампами у всех пользователей | Windows Server (PowerShell 5.1 или 7+) |
| `clear-crashdumps.sh` | то же для Linux | Linux/Unix-сервер (bash 4+, GNU findutils) |

Обычный порядок работы: сначала `Get-DiskUsage.ps1`, чтобы понять, куда ушло место,
потом целевая очистка.

# Очистка папок с аварийными дампами у всех пользователей

Оба скрипта по умолчанию **удаляют только содержимое** папок с дампами, сами папки
остаются на месте (Windows Error Reporting и приложения ожидают их существования).
Имена папок ищутся без учёта регистра: `crushdumps` и `crashdumps`.

## Linux

```bash
sudo ./clear-crashdumps.sh --dry-run          # посмотреть, что будет удалено
sudo ./clear-crashdumps.sh                    # очистить
sudo ./clear-crashdumps.sh --older-than 7     # только дампы старше 7 суток
sudo ./clear-crashdumps.sh --min-uid 0 --include-root   # включая служебные и root
sudo ./clear-crashdumps.sh --dir dumps --dir minidumps  # другие имена папок
```

Что делает:

* берёт список пользователей из `getent passwd` (работает и с LDAP/AD через SSSD);
* обрабатывает учётные записи с UID >= 1000 (`--min-uid` меняет порог);
* ищет папки с дампами в домашнем каталоге на глубине до 3 уровней (`--max-depth`),
  поэтому находит и `AppData/Local/CrashDumps` у роуминг-профилей Windows,
  лежащих на Linux-файловом сервере;
* пропускает системные и подозрительные домашние каталоги (`/`, `/var`, `/usr`,
  `/nonexistent` и т. п.), символические ссылки и не выходит за границы файловой
  системы при удалении;
* печатает по каждому каталогу число файлов и объём, в конце — итог.

Запуск по расписанию, каждую ночь в 3:20, дампы старше 7 суток:

```cron
20 3 * * * /usr/local/sbin/clear-crashdumps.sh --older-than 7 --quiet >> /var/log/clear-crashdumps.log 2>&1
```

## Windows

```powershell
.\Clear-CrashDumps.ps1 -WhatIf              # посмотреть, что будет удалено
.\Clear-CrashDumps.ps1                      # очистить
.\Clear-CrashDumps.ps1 -OlderThanDays 7     # только дампы старше 7 суток
.\Clear-CrashDumps.ps1 -RemoveDir           # удалить и сами папки
.\Clear-CrashDumps.ps1 -ProfilePath D:\Profiles\ivanov   # конкретный профиль
```

Отчёт печатается в стандартный поток вывода, поэтому его можно перенаправлять в лог
(`.\Clear-CrashDumps.ps1 -OlderThanDays 7 >> C:\Scripts\clear-crashdumps.log`).

Профили берутся из реестра
`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList`, поэтому находятся
и профили вне `C:\Users`. Системные учётные записи пропускаются, включить их можно
через `-IncludeSystemProfiles`. Запускать от имени администратора.

Задание в планировщике (ежедневно в 3:20):

```powershell
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NonInteractive -ExecutionPolicy Bypass -File C:\Scripts\Clear-CrashDumps.ps1 -OlderThanDays 7'
$trigger = New-ScheduledTaskTrigger -Daily -At 03:20
Register-ScheduledTask -TaskName 'Clear CrashDumps' -Action $action -Trigger $trigger `
    -User 'SYSTEM' -RunLevel Highest
```

## Если PowerShell 5.1 ругается «Непредвиденная лексема ")"»

Симптом — в тексте ошибки вместо русских слов каша вида `РЈРґР°Р»РёС‚СЊ`:

```
Непредвиденная лексема ")" в выражении или операторе.
C:\...\Clear-CrashDumps.ps1:133 знак:94
+ ... houldProcess($file.FullName, 'РЈРґР°Р»РёС‚СЊ С„Р°Р№Р» РґР°РјРїР°')) {
```

Причина не в коде: Windows PowerShell 5.1 читает `.ps1` без BOM как ANSI (cp1251),
и байты UTF-8 распадаются на мусор, среди которого попадаются типографские кавычки
(`‚`, `“`, `„`) — парсер принимает их за настоящие и теряет строку.

В репозитории файл лежит в UTF-8 **с BOM**, поэтому проблемы быть не должно. Если
вы пересохраняли его вручную (Блокнот, копирование из браузера), верните BOM:

```powershell
$p = 'C:\Users\d.shimonov.OFFICE\Desktop\crushdumps.ps1'
$text = [IO.File]::ReadAllText($p, (New-Object Text.UTF8Encoding $false))
[IO.File]::WriteAllText($p, $text, (New-Object Text.UTF8Encoding $true))
```

Альтернативы: сохранить файл в «UTF-8 with BOM» или «UTF-16 LE» из редактора либо
запускать через PowerShell 7 (`pwsh.exe`), который по умолчанию считает `.ps1` UTF-8.

## Если PowerShell пишет «Переменная "$IsWindows" не может быть получена»

Значит, у вас на диске версия скрипта до исправления: `$IsWindows` появился только
в PowerShell 6, а под `Set-StrictMode` обращение к несуществующей переменной —
фатальная ошибка. Проще всего скачать файл заново, но можно поправить и на месте
(BOM при этом сохраняется):

```powershell
$p = 'C:\Users\d.shimonov.OFFICE\Desktop\crushdumps.ps1'
$enc = New-Object Text.UTF8Encoding $true
$text = [IO.File]::ReadAllText($p, $enc) -replace '\$IsWindows -or ', ''
[IO.File]::WriteAllText($p, $text, $enc)
```

## Перед первым боевым запуском

Прогоните с `--dry-run` / `-WhatIf` и убедитесь, что в списке нет ничего лишнего:
скрипты удаляют файлы безвозвратно, в корзину они не попадают.

# Как понять, что занимает место на сервере

## Скриптом

```powershell
.\Get-DiskUsage.ps1                                       # все диски, каталоги первого уровня
.\Get-DiskUsage.ps1 -Path C:\ -Depth 2 -Top 30            # подробнее по системному диску
.\Get-DiskUsage.ps1 -Path C:\ -IncludeFiles               # плюс самые большие файлы
.\Get-DiskUsage.ps1 >> C:\Scripts\diskusage.log           # отчёт в файл
```

Скрипт печатает три блока: занятое/свободное место по дискам, самые тяжёлые каталоги
и типовых «пожирателей» места (`Windows\Temp`, `SoftwareDistribution\Download`,
`Windows\Installer`, `WinSxS`, `WER`, корзины, пользовательские `Temp` и `CrashDumps`,
`pagefile.sys`, `hiberfil.sys`). Точки повторной обработки (junction, симлинки) не
разворачиваются, поэтому одно и то же место не считается дважды. Запускать от имени
администратора: иначе часть каталогов будет молча пропущена.

Подсчёт идёт перебором файлов, на диске с миллионами файлов это десятки минут. Если
нужен мгновенный результат — **WizTree** читает MFT напрямую и отрабатывает за
секунды; **TreeSize Free** и **WinDirStat** удобнее визуально, но считают так же
медленно.

## Вручную, по шагам

Сверху вниз: диск → крупные каталоги → конкретные файлы.

```powershell
Get-Volume                                                # свободное место по томам

# самые тяжёлые каталоги первого уровня
Get-ChildItem C:\ -Directory -Force | ForEach-Object {
    $s = (Get-ChildItem $_.FullName -File -Recurse -Force -ErrorAction SilentlyContinue |
          Measure-Object Length -Sum).Sum
    [pscustomobject]@{ GB = [math]::Round($s / 1GB, 2); Path = $_.FullName }
} | Sort-Object GB -Descending

# самые большие файлы
Get-ChildItem C:\ -File -Recurse -Force -ErrorAction SilentlyContinue |
    Sort-Object Length -Descending | Select-Object -First 20 Length, FullName
```

Что почти всегда стоит проверить отдельно, потому что в такой разбивке это легко
пропустить:

```powershell
vssadmin list shadowstorage                               # теневые копии, часто десятки ГБ
Dism /Online /Cleanup-Image /AnalyzeComponentStore         # реальный «вес» WinSxS
Dism /Online /Cleanup-Image /StartComponentCleanup         # и его очистка
Get-WinEvent -ListLog * | Sort-Object FileSize -Descending |
    Select-Object -First 10 LogName, FileSize              # разросшиеся журналы событий
Get-ChildItem 'C:\Windows\Temp', 'C:\Windows\SoftwareDistribution\Download' -Recurse -Force |
    Measure-Object Length -Sum                             # мусор обновлений
```

Отдельные частые причины на Windows Server: журналы IIS в `C:\inetpub\logs`, бэкапы
и логи SQL Server (`.bak`, `.ldf`), профили пользователей на терминальном сервере,
`C:\Windows\Installer` (кэш MSI — удалять оттуда вручную нельзя, чистить только
`msizap`/переустановкой), файл подкачки и файл гибернации
(`powercfg /hibernate off` освобождает объём, равный размеру ОЗУ).

## На Linux

```bash
df -hT                                      # что вообще заполнено
du -xh --max-depth=1 / 2>/dev/null | sort -h | tail -20   # крупные каталоги, не выходя за ФС
du -xh --max-depth=1 /var | sort -h | tail  # спускаемся глубже по самому тяжёлому
ncdu -x /                                   # интерактивно, если можно поставить пакет
find / -xdev -type f -size +1G -exec ls -lh {} + 2>/dev/null   # файлы-гиганты
journalctl --disk-usage                     # журналы systemd
```

Классическая ловушка: `df` показывает занятое место, а `du` — нет. Значит, файл удалён,
но его держит открытым процесс, и место вернётся только после перезапуска сервиса:

```bash
sudo lsof -nP +L1 | sort -k7 -n | tail      # удалённые, но всё ещё открытые файлы
```

Вторая ловушка — кончились не байты, а inode (`df -i`): обычно это миллионы мелких
файлов в каталогах сессий, очередях почты или тех же дампах.
