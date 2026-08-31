# Очистка папок с аварийными дампами у всех пользователей

Два независимых скрипта, выбирайте по ОС сервера:

| Файл | Где запускать |
| --- | --- |
| `clear-crashdumps.sh` | Linux/Unix-сервер (bash 4+, GNU findutils) |
| `Clear-CrashDumps.ps1` | Windows Server (PowerShell 5.1 или 7+) |

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

## Перед первым боевым запуском

Прогоните с `--dry-run` / `-WhatIf` и убедитесь, что в списке нет ничего лишнего:
скрипты удаляют файлы безвозвратно, в корзину они не попадают.
