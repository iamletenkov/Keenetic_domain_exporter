#!/bin/sh
# Экспорт FQDN-групп из running-config в ./lists рядом со скриптом.
# Имя файла = description (санитизировано). Если пусто — имя группы (domain-listN).
# По умолчанию пишем только include-домены (plain). Можно переключить:
#   EXPORT_MODE=actions sh export.sh   # писать "include fqdn"/"exclude fqdn"
#
# Зависит от: ndmc (родной для Keenetic). Совместимо с BusyBox ash/awk.

set -eu

# --- Entware в PATH на всякий случай ---
PATH="/opt/bin:/opt/sbin:$PATH"

# --- пути ---
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUT_DIR="$SCRIPT_DIR/lists"

# --- режим содержимого файла ---
MODE="${EXPORT_MODE:-plain}"   # plain | actions

# --- проверка ndmc ---
if ! command -v ndmc >/dev/null 2>&1; then
    echo "Ошибка: команда 'ndmc' не найдена. Запусти скрипт на Keenetic с установленным Entware." >&2
    exit 1
fi

mkdir -p "$OUT_DIR" || {
    echo "Не удалось создать каталог $OUT_DIR" >&2
    exit 1
}

echo "Каталог для экспорта: $OUT_DIR"
echo "Читаю running-config через ndmc ..."

CFG="$(mktemp)"
if ! ndmc -c "show running-config" >"$CFG" 2>/dev/null; then
    echo "Ошибка: ndmc -c 'show running-config' не отдал конфиг." >&2
    rm -f "$CFG"
    exit 1
fi

if [ ! -s "$CFG" ]; then
    echo "Предупреждение: running-config пуст. Нечего экспортировать."
    rm -f "$CFG"
    exit 0
fi

# Парсим блоки вида:
# object-group fqdn domain-listN
#   description <desc>
#   include fqdn
#   exclude fqdn
# !
#
# Экспортируем ТОЛЬКО группы domain-list[0-9]+
awk -v outdir="$OUT_DIR" -v mode="$MODE" '
function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
function trim(s){ return rtrim(ltrim(s)) }
function sanitize_filename(s) {
  s = trim(s)
  gsub(/[^A-Za-z0-9._-]/, "_", s)
  if (s == "") s = "unnamed"
  return s
}
function reset() { inb=0; group=""; desc=""; delete inc; delete exc }
function flush() {
  if (!inb) return
  # имя файла из description (или из group), + уникализация
  base = sanitize_filename(desc); if (base == "" || base == "unnamed") base = group
  key = base
  if (!(key in seen)) seen[key]=0
  seen[key]++
  fname = base
  if (seen[key] > 1) fname = base "__" group

  outfile = outdir "/" fname ".txt"

  # запись содержимого
  if (mode == "actions") {
    for (d in inc) print "include " d > outfile
    for (d in exc) print "exclude " d > outfile
  } else {
    for (d in inc) print d > outfile
  }
  close(outfile)

  printf("  -> %s (group=%s, desc=\"%s\")\n", outfile, group, desc)

  reset()
}
BEGIN { reset() }
# старт блока группы
$1=="object-group" && $2=="fqdn" && $3 ~ /^domain-list[0-9]+$/ { flush(); inb=1; group=$3; next }
# описание
inb && $1=="description" {
  $1=""; desc=trim($0); next
}
# include/exclude
inb && $1=="include" && $2!="" { fq=$2; sub(/^\./,"",fq); inc[fq]=1; next }
inb && $1=="exclude" && $2!="" { fq=$2; sub(/^\./,"",fq); exc[fq]=1; next }
# конец блока
inb && $0 ~ /^[[:space:]]*![[:space:]]*$/ { flush(); next }
END { flush() }
' "$CFG"

count=$(ls -1 "$OUT_DIR" 2>/dev/null | wc -l | awk '{print $1}')
echo "Готово: экспортировано файлов — $count в $OUT_DIR"

rm -f "$CFG"
