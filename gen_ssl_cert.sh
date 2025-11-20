#!/bin/bash
set -euo pipefail

# ====== Цвета и символы ======
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[1;36m'
NC='\033[0m'
CHECK="${GREEN}✔${NC}"
WARN="${YELLOW}⚠${NC}"
ERR="${RED}✖${NC}"

# ====== Пути ======
DB_PATH="/etc/x-ui/x-ui.db"
BACKUP_DIR="/etc/x-ui/backups"
SSL_CERT="/etc/ssl/certs/3x-ui-public.key"
SSL_KEY="/etc/ssl/private/3x-ui-private.key"

mkdir -p "$BACKUP_DIR"
mkdir -p "$(dirname "$SSL_KEY")"
mkdir -p "$(dirname "$SSL_CERT")"

# ====== Проверка root ======
if [ "$EUID" -ne 0 ]; then
    echo -e "${ERR} Запустите скрипт с правами root."
    exit 1
fi

# ====== Функции ======

# --- Создание бекапа базы ---
create_backup() {
    TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    BACKUP_FILE="$BACKUP_DIR/x-ui.db.$TIMESTAMP.bak"
    if [ ! -f "$DB_PATH" ]; then
        echo -e "${ERR} Файл базы данных не найден: $DB_PATH"
        return
    fi
    cp "$DB_PATH" "$BACKUP_FILE"
    echo -e "${CHECK} Бекап создан: $BACKUP_FILE"
}

# --- Восстановление базы из бекапа ---
restore_backup() {
    local backups=($(ls -1 "$BACKUP_DIR" | grep "x-ui.db.*\.bak" | sort))
    if [ ${#backups[@]} -eq 0 ]; then
        echo -e "${WARN} Бекапы не найдены в $BACKUP_DIR"
        return
    fi

    echo -e "${CYAN}Доступные бекапы:${NC}"
    for i in "${!backups[@]}"; do
        echo "$i) ${backups[$i]}"
    done

    read -p "Введите номер бекапа для восстановления: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -ge ${#backups[@]} ]; then
        echo -e "${ERR} Неверный выбор."
        return
    fi

    SELECTED_BACKUP="$BACKUP_DIR/${backups[$choice]}"
    cp "$SELECTED_BACKUP" "$DB_PATH"
    echo -e "${CHECK} База успешно восстановлена из $SELECTED_BACKUP"
}

# --- Проверка и установка sqlite3 ---
check_sqlite3() {
    if ! command -v sqlite3 &> /dev/null; then
        echo -e "${WARN} sqlite3 не найден, устанавливаем..."
        install_sqlite3
    else
        echo -e "${CHECK} sqlite3 установлен."
    fi
}

install_sqlite3() {
    if [ -x "$(command -v apt-get)" ]; then
        apt-get update -y && apt-get install -y sqlite3
    elif [ -x "$(command -v yum)" ]; then
        yum install -y sqlite
    elif [ -x "$(command -v dnf)" ]; then
        dnf install -y sqlite
    elif [ -x "$(command -v pacman)" ]; then
        pacman -S --noconfirm sqlite
    else
        echo -e "${ERR} Менеджер пакетов не найден. Установите sqlite3 вручную."
        exit 1
    fi
}

# --- Проверка и установка openssl ---
check_openssl() {
    if ! command -v openssl &> /dev/null; then
        echo -e "${WARN} openssl не найден, устанавливаем..."
        install_openssl
    else
        echo -e "${CHECK} openssl установлен."
    fi
}

install_openssl() {
    if [ -x "$(command -v apt-get)" ]; then
        apt-get update -y && apt-get install -y openssl
    elif [ -x "$(command -v yum)" ]; then
        yum install -y openssl
    elif [ -x "$(command -v dnf)" ]; then
        dnf install -y openssl
    elif [ -x "$(command -v pacman)" ]; then
        pacman -S --noconfirm openssl
    else
        echo -e "${ERR} Менеджер пакетов не найден. Установите openssl вручную."
        exit 1
    fi
}

# --- Генерация самоподписанного сертификата ---
gen_ssl_cert() {
    check_sqlite3
    check_openssl

    # Проверка существующего сертификата
    local existing=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webCertFile' LIMIT 1;")
    if [ -n "$existing" ]; then
        echo -e "${WARN} SSL уже прописан: $existing"
        return
    fi

    # Создаём бэкап базы перед изменением
    create_backup

    # OpenSSL конфиг для SAN
    TMP_CONF=$(mktemp)
    cat > "$TMP_CONF" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = 3x-ui.local

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = 3x-ui.local
IP.1 = 127.0.0.1
EOF

    openssl req -x509 -nodes -newkey rsa:4096 \
        -keyout "$SSL_KEY" \
        -out "$SSL_CERT" \
        -days 3650 -sha256 \
        -config "$TMP_CONF"

    chmod 600 "$SSL_KEY"
    chmod 644 "$SSL_CERT"
    chown root:root "$SSL_KEY" "$SSL_CERT"

    # Вставка в базу через INSERT OR REPLACE
    sqlite3 "$DB_PATH" <<SQL
BEGIN;
INSERT OR REPLACE INTO settings (key,value) VALUES ('webCertFile','$SSL_CERT');
INSERT OR REPLACE INTO settings (key,value) VALUES ('webKeyFile','$SSL_KEY');
COMMIT;
SQL

    echo -e "${CHECK} Самоподписанный SSL установлен. Перезапустите 3X-UI для применения."
    rm -f "$TMP_CONF"
}

# ====== Главное меню ======
while true; do
    echo -e "\n${CYAN}===== 3X-UI Maintenance Menu =====${NC}"
    echo "1) Backup Database      - Создать резервную копию базы"
    echo "2) Restore Database     - Восстановить базу из бекапа"
    echo "3) Install Self-Signed SSL - Установить сертификат на 10 лет"
    echo "0) Exit                 - Выход"
    echo -n "Выберите действие [0-3]: "
    read choice

    case "$choice" in
        1) create_backup ;;
        2) restore_backup ;;
        3) gen_ssl_cert ;;
        0) echo "Выход..."; exit 0 ;;
        *) echo -e "${WARN} Неверный выбор." ;;
    esac
done
