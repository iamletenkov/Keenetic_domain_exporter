#!/bin/sh
# Импорт FQDN-групп из ./lists рядом со скриптом.
# Имя файла (без .txt) = description группы.
# Конфиг читаем через: ndmc -c "show running-config"
# Команды в конфиг отправляем через: ndmq -p "<cmd>"

set -eu

# ---- базовые пути ----
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LISTS_DIR="$SCRIPT_DIR/lists"

# верхняя граница индексов для авто-выделения domain-listN (можно переопределить через env)
MAX_INDEX="${MAX_INDEX:-199}"

IFACE=""
APPLY_ROUTE=1
DRY_RUN=0
SAVE=1

usage() {
  cat <<EOF
Usage: $0 [-i IFACE] [-d DIR] [--no-route] [--dry-run] [--no-save]
  -i IFACE     Использовать указанный VPN-интерфейс (без меню)
  -d DIR       Папка со списками (default: ./lists рядом со скриптом)
  --no-route   Не настраивать dns-proxy route
  --dry-run    Только печатать команды, не выполнять
  --no-save    Не делать 'system configuration save'
Env:
  MAX_INDEX    Макс. индекс для auto domain-listN (default: 199)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -i) IFACE="$2"; shift 2 ;;
    -d) LISTS_DIR="$2"; shift 2 ;;
    --no-route) APPLY_ROUTE=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-save) SAVE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

# ---- Entware PATH ----
[ -r /opt/etc/profile ] && . /opt/etc/profile || true
export PATH="/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# ---- проверяем ndmc ----
if ! command -v ndmc >/dev/null 2>&1; then
  echo "Ошибка: 'ndmc' не найден. Нужен для чтения running-config." >&2
  exit 1
fi

# ---- обеспечиваем ndmq ----
ensure_ndmq() {
  if command -v ndmq >/dev/null 2>&1; then
    command -v ndmq
    return 0
  fi
  echo "ndmq не найден — пробую поставить через opkg..." >&2
  if ! command -v opkg >/dev/null 2>&1; then
    echo "ERROR: opkg не найден. Настрой Entware." >&2
    return 1
  fi
  opkg update || true
  opkg install ndmq || {
    echo "ERROR: не удалось установить ndmq." >&2
    return 1
  }
  command -v ndmq
}

NDMQ="$(ensure_ndmq)"

uslp() { usleep 50000 2>/dev/null || sleep 0.05; }

run_cli() {
  CMD="$*"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "$NDMQ -p \"$CMD\""
  else
    $NDMQ -p "$CMD" >/dev/null
    uslp
  fi
}

escape_desc() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# ---- читаем running-config ----
CFG="$(mktemp)"
echo ">>> Читаю running-config через ndmc ..."
if ! ndmc -c "show running-config" > "$CFG" 2>/dev/null; then
  echo "ERROR: ndmc -c 'show running-config' не вернул конфиг." >&2
  rm -f "$CFG"
  exit 1
fi

if [ ! -s "$CFG" ]; then
  echo "WARN: running-config пуст." >&2
fi

# ---- строим карту description -> group ----
DESC_MAP="$(mktemp)"   # <description>\t<group>
awk '
  $1=="object-group" && $2=="fqdn" {
    g=$3; inb=1; d="";
    next
  }
  inb && $1=="description" {
    $1=""; sub(/^[[:space:]]+/, "", $0); d=$0;
    next
  }
  inb && $0 ~ /^[[:space:]]*!/ {
    if (d!="") print d "\t" g;
    inb=0;
    next
  }
  END {
    if (inb && d!="") print d "\t" g;
  }
' "$CFG" > "$DESC_MAP"

# ---- список занятых групп ----
USED_GROUPS_CFG="$(mktemp)"
awk '$1=="object-group" && $2=="fqdn" {print $3}' "$CFG" | sort -u > "$USED_GROUPS_CFG"

# ---- собираем VPN-интерфейсы ----
VPN_TMP="$(mktemp)"
awk '
  tolower($1)=="interface" {
    name=$2; n=tolower(name);
    if (n ~ /^(wireguard|openvpn|l2tp|pptp|sstp|ipsec)/) print name;
  }
' "$CFG" | sort -u > "$VPN_TMP"

pick_iface() {
  # Если передали -i — просто возвращаем его
  if [ -n "$IFACE" ]; then
    echo "$IFACE"
    return 0
  fi

  if [ ! -s "$VPN_TMP" ]; then
    echo "Не найдено VPN-интерфейсов в конфиге." >&2
    printf "Введи имя интерфейса вручную (например, Wireguard1): " >/dev/tty
    read -r manual </dev/tty
    echo "$manual"
    return 0
  fi

  echo "Найдены VPN-интерфейсы:" >/dev/tty
  i=1
  while IFS= read -r name; do
    echo "  [$i] $name" >/dev/tty
    i=$((i+1))
  done < "$VPN_TMP"

  printf "Выбери номер [1]: " >/dev/tty
  read -r choice </dev/tty
  [ -z "${choice:-}" ] && choice=1

  sel="$(sed -n "${choice}p" "$VPN_TMP")"
  if [ -z "$sel" ]; then
    echo "Некорректный выбор, беру первый." >&2
    sel="$(sed -n '1p' "$VPN_TMP")"
  fi
  echo "$sel"
}

IFACE="$(pick_iface)"
IFACE="$(printf '%s' "$IFACE" | tr -d '[:space:]')"
if [ -z "$IFACE" ]; then
  echo "ERROR: интерфейс не выбран." >&2
  rm -f "$CFG" "$DESC_MAP" "$USED_GROUPS_CFG" "$VPN_TMP"
  exit 1
fi
echo ">>> Использую интерфейс: $IFACE"

# ---- аллокация групп ----
USED_TARGET_GROUPS="$(mktemp)"
is_used_cfg_group()     { grep -qx "$1" "$USED_GROUPS_CFG"; }
is_used_target_group()  { grep -qx "$1" "$USED_TARGET_GROUPS"; }
mark_target_group_used(){ echo "$1" >> "$USED_TARGET_GROUPS"; }

alloc_free_group() {
  i=0
  while [ "$i" -le "$MAX_INDEX" ]; do
    g="domain-list$i"
    if ! is_used_cfg_group "$g" && ! is_used_target_group "$g"; then
      echo "$g"
      return 0
    fi
    i=$((i+1))
  done
  echo ""
  return 1
}

group_by_desc_first_free() { # $1=desc
  D="$1"
  awk -F '\t' -v d="$D" '$1==d {print $2}' "$DESC_MAP" \
  | while IFS= read -r g; do
      [ -z "$g" ] && continue
      if ! is_used_target_group "$g"; then
        echo "$g"
        break
      fi
    done
}

# ---- основная обработка файлов ----
if [ ! -d "$LISTS_DIR" ]; then
  echo "Папка со списками не найдена: $LISTS_DIR" >&2
  rm -f "$CFG" "$DESC_MAP" "$USED_GROUPS_CFG" "$VPN_TMP" "$USED_TARGET_GROUPS"
  exit 1
fi

echo ">>> Импортирую списки из: $LISTS_DIR"
FOUND=0

# обрабатываем файлы в алфавитном порядке
for fname in $(ls -1 "$LISTS_DIR" 2>/dev/null | LC_ALL=C sort); do
  f="$LISTS_DIR/$fname"
  [ -f "$f" ] || continue
  FOUND=1

  base="$fname"
  desc="${base%.*}"
  [ -z "$desc" ] && desc="$base"

  # ищем существующую группу по description
  GROUP="$(group_by_desc_first_free "$desc" || true)"
  if [ -z "$GROUP" ]; then
    GROUP="$(alloc_free_group || true)"
    if [ -z "$GROUP" ]; then
      echo "ERROR: нет свободных domain-listN для \"$desc\"." >&2
      continue
    fi
    echo ">>> [$fname] создаю группу: $GROUP  (description: \"$desc\")"
  else
    echo ">>> [$fname] обновляю группу: $GROUP  (description: \"$desc\")"
  fi
  mark_target_group_used "$GROUP"

  # пересоздаём группу и описание
  run_cli "no object-group fqdn $GROUP" || true
  run_cli "object-group fqdn $GROUP"
  ESC_DESC="$(escape_desc "$desc")"
  run_cli "object-group fqdn $GROUP description \"$ESC_DESC\""

  # читаем файл и добавляем include/exclude
  tr -d '\r' < "$f" | while IFS= read -r raw || [ -n "$raw" ]; do
    case "$raw" in \#*) continue ;; esac
    line="$(echo "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue

    action="include"; val="$line"
    case "$line" in
      include\ *) val="${line#include }" ;;
      exclude\ *) val="${line#exclude }"; action="exclude" ;;
      \!*|-\ *)  val="$(echo "${line#?}" | sed -e 's/^[[:space:]]*//')"; action="exclude" ;;
    esac
    case "$val" in .*) val="${val#.}";; esac
    [ -z "$val" ] && continue

    run_cli "object-group fqdn $GROUP $action $val"
  done

  if [ "$APPLY_ROUTE" -eq 1 ]; then
    run_cli "dns-proxy route object-group $GROUP $IFACE auto"
  fi
done

if [ "$FOUND" -eq 0 ]; then
  echo "В папке $LISTS_DIR нет файлов для импорта."
  rm -f "$CFG" "$DESC_MAP" "$USED_GROUPS_CFG" "$VPN_TMP" "$USED_TARGET_GROUPS"
  exit 0
fi

if [ "$SAVE" -eq 1 ]; then
  echo ">>> Сохраняю конфигурацию..."
  run_cli "system configuration save"
else
  echo ">>> Пропускаю 'system configuration save' (запусти без --no-save для сохранения)"
fi

rm -f "$CFG" "$DESC_MAP" "$USED_GROUPS_CFG" "$VPN_TMP" "$USED_TARGET_GROUPS"
echo "Готово."
