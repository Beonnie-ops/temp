#!/usr/bin/env bash
#
# Очистка каталогов аварийных дампов (crushdumps / crashdumps) у всех
# пользователей сервера.
#
# По умолчанию скрипт:
#   * перебирает всех пользователей из базы passwd (getent passwd);
#   * берёт только учётные записи с UID >= 1000 (реальные люди, не сервисные);
#   * ищет в домашнем каталоге папки с именем crushdumps/crashdumps
#     (регистр не важен) на глубине до 3 уровней, чтобы находить и
#     AppData/Local/CrashDumps у роуминг-профилей Windows на файловом сервере;
#   * удаляет содержимое найденных папок, сама папка остаётся на месте.
#
# Примеры:
#   sudo ./clear-crashdumps.sh --dry-run             # показать, что будет удалено
#   sudo ./clear-crashdumps.sh                       # очистить всё
#   sudo ./clear-crashdumps.sh --older-than 7        # удалить дампы старше 7 суток
#   sudo ./clear-crashdumps.sh --min-uid 0 --include-root
#   sudo ./clear-crashdumps.sh --dir dumps --dir minidumps
#
set -euo pipefail

readonly PROGNAME="${0##*/}"

dir_names=()
older_than=""
min_uid=1000
max_depth=3
include_root=0
remove_dir=0
dry_run=0
quiet=0
passwd_file=""

usage() {
	cat <<EOF
Использование: $PROGNAME [опции]

Опции:
  -n, --dry-run          ничего не удалять, только показать список и объём
      --dir ИМЯ          имя каталога с дампами (можно указать несколько раз;
                         по умолчанию: crushdumps, crashdumps)
      --older-than ДНИ   удалять только файлы, изменённые более ДНИ суток назад
      --min-uid N        минимальный UID пользователя (по умолчанию 1000)
      --include-root     обрабатывать также /root (UID 0)
      --max-depth N      глубина поиска внутри домашнего каталога (по умолчанию 3)
      --remove-dir       удалить и саму папку, а не только её содержимое
      --passwd-file ФАЙЛ читать список пользователей из файла в формате passwd
                         (удобно для проверки скрипта на тестовых данных)
  -q, --quiet            выводить только итоговую строку
  -h, --help             показать эту справку

Код возврата: 0 — успех, 1 — ошибка параметров или окружения.
EOF
}

log() { ((quiet)) || printf '%s\n' "$*"; }
warn() { printf '%s: %s\n' "$PROGNAME" "$*" >&2; }
die() {
	warn "$*"
	exit 1
}

human() {
	awk -v b="$1" 'BEGIN {
		split("B KiB MiB GiB TiB", u, " ")
		i = 1
		while (b >= 1024 && i < 5) { b /= 1024; i++ }
		if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]
	}'
}

while (($#)); do
	case $1 in
	-n | --dry-run) dry_run=1 ;;
	--dir)
		[[ ${2:-} ]] || die "--dir требует имя каталога"
		dir_names+=("$2")
		shift
		;;
	--older-than)
		[[ ${2:-} =~ ^[0-9]+$ ]] || die "--older-than требует число суток"
		older_than=$2
		shift
		;;
	--min-uid)
		[[ ${2:-} =~ ^[0-9]+$ ]] || die "--min-uid требует число"
		min_uid=$2
		shift
		;;
	--max-depth)
		[[ ${2:-} =~ ^[1-9][0-9]*$ ]] || die "--max-depth требует число больше нуля"
		max_depth=$2
		shift
		;;
	--include-root) include_root=1 ;;
	--remove-dir) remove_dir=1 ;;
	--passwd-file)
		[[ -r ${2:-} ]] || die "не могу прочитать файл ${2:-<не задан>}"
		passwd_file=$2
		shift
		;;
	-q | --quiet) quiet=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "неизвестный параметр: $1 (см. --help)" ;;
	esac
	shift
done

((${#dir_names[@]})) || dir_names=(crushdumps crashdumps)

command -v getent >/dev/null 2>&1 || [[ -n $passwd_file ]] ||
	die "не найден getent, укажите --passwd-file"

if ((EUID != 0)) && ((dry_run == 0)); then
	warn "скрипт запущен не от root: чужие домашние каталоги, скорее всего, будут пропущены"
fi

# Домашние каталоги, которые никогда не трогаем.
is_forbidden_home() {
	case $1 in
	/ | /bin | /boot | /dev | /etc | /home | /lib | /nonexistent | /proc | \
		/run | /sbin | /srv | /sys | /tmp | /usr | /var | /var/empty | \
		/var/run | /dev/null | "")
		return 0
		;;
	esac
	[[ $1 != /* ]] && return 0
	return 1
}

name_expr=()
for name in "${dir_names[@]}"; do
	((${#name_expr[@]})) && name_expr+=(-o)
	name_expr+=(-iname "$name")
done

total_files=0
total_bytes=0
total_dirs=0
declare -A seen_home=()

# Считает файлы и их суммарный размер в каталоге с учётом фильтра по возрасту.
target_stats() {
	local target=$1
	local -a age=()
	[[ -n $older_than ]] && age=(-mtime "+$older_than")
	find "$target" -xdev -mindepth 1 -type f "${age[@]}" -printf '%s\n' 2>/dev/null |
		awk '{ c++; s += $1 } END { print (c + 0), (s + 0) }'
}

clean_target() {
	local user=$1 target=$2 files bytes

	read -r files bytes < <(target_stats "$target")
	total_dirs=$((total_dirs + 1))
	total_files=$((total_files + files))
	total_bytes=$((total_bytes + bytes))

	local prefix=""
	((dry_run)) && prefix="[dry-run] "
	log "${prefix}${user}: ${target} — файлов: ${files}, объём: $(human "$bytes")"

	((dry_run)) && return 0

	local -a age=()
	[[ -n $older_than ]] && age=(-mtime "+$older_than")

	if ((${#age[@]})); then
		find "$target" -xdev -mindepth 1 ! -type d "${age[@]}" -delete 2>/dev/null ||
			warn "не всё удалось удалить в $target"
		# Пустые подкаталоги удаляем снизу вверх, сам target не трогаем.
		find "$target" -xdev -mindepth 1 -type d -empty -delete 2>/dev/null || true
	else
		find "$target" -xdev -mindepth 1 -delete 2>/dev/null ||
			warn "не всё удалось удалить в $target"
	fi

	if ((remove_dir)); then
		rmdir "$target" 2>/dev/null || warn "каталог $target не пуст, оставлен на месте"
	fi
}

while IFS=: read -r user _pw uid _gid _gecos home _shell; do
	[[ -z ${user:-} || $user == \#* ]] && continue
	[[ ${uid:-} =~ ^[0-9]+$ ]] || continue

	if ((uid < min_uid)); then
		((include_root)) && ((uid == 0)) || continue
	fi

	is_forbidden_home "${home:-}" && continue
	[[ -d $home ]] || continue
	[[ -L $home ]] && continue
	[[ -n ${seen_home[$home]:-} ]] && continue
	seen_home[$home]=1

	while IFS= read -r -d '' target; do
		clean_target "$user" "$target"
	done < <(find "$home" -mindepth 1 -maxdepth "$max_depth" -type d \
		\( "${name_expr[@]}" \) -print0 2>/dev/null)
done < <(if [[ -n $passwd_file ]]; then cat -- "$passwd_file"; else getent passwd; fi)

if ((dry_run)); then
	printf 'Итого (без удаления): каталогов %d, файлов %d, объём %s\n' \
		"$total_dirs" "$total_files" "$(human "$total_bytes")"
else
	printf 'Итого очищено: каталогов %d, файлов %d, освобождено %s\n' \
		"$total_dirs" "$total_files" "$(human "$total_bytes")"
fi
