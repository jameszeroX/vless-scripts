#!/bin/bash

# Значение порта по умолчанию
SPORT=9000
WITHOUT_80=0
SELF_SIGNED=0
RAND_DNS=0

# Разбор аргументов
while [[ $# -gt 0 ]]; do
    case "$1" in
        --selfsni-port)
            if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
                SPORT="$2"
                shift 2
            else
                echo "Ошибка: укажите корректный порт после аргумента --selfsni-port."
                exit 1
            fi
            ;;
        --without-80)
            WITHOUT_80=1
            shift
            ;;
        --self-signed)
            SELF_SIGNED=1
            shift
            ;;
        --rand-dns)
            RAND_DNS=1
            shift
            ;;
        *)
            echo "Неизвестный аргумент: $1"
            echo "Использование:"
            echo "$0 [--selfsni-port <порт>] [--without-80] [--self-signed] [--rand-dns]"
            exit 1
            ;;
    esac
done

# --rand-dns только вместе с --self-signed
if [[ $RAND_DNS -eq 1 && $SELF_SIGNED -eq 0 ]]; then
    echo "Ошибка: --rand-dns можно использовать только вместе с --self-signed"
    exit 1
fi

# Проверка системы
if ! grep -E -q "^(ID=debian|ID=ubuntu)" /etc/os-release; then
    echo "Скрипт поддерживает только Debian или Ubuntu. Завершаю работу."
    exit 1
fi

# Генерация случайного .ru домена
generate_random_domain() {
    local chars="abcdefghijklmnopqrstuvwxyz"
    local length=$((RANDOM % 6 + 8))
    local name=""

    for ((i=0; i<length; i++)); do
        name+="${chars:RANDOM%${#chars}:1}"
    done

    echo "${name}.ru"
}

# Получение домена
if [[ $RAND_DNS -eq 1 ]]; then

    DOMAIN=$(generate_random_domain)

    echo "Сгенерирован случайный домен: $DOMAIN"

else

    read -p "Введите доменное имя: " DOMAIN

    if [[ -z "$DOMAIN" ]]; then
        echo "Доменное имя не может быть пустым. Завершаю работу."
        exit 1
    fi

fi

# Проверки DNS/IP только НЕ для self-signed режима
if [[ $SELF_SIGNED -eq 0 ]]; then

    # Получение внешнего IP сервера
    external_ip=$(curl -s --max-time 3 https://api.ipify.org)

    # Проверка, что curl успешно получил IP
    if [[ -z "$external_ip" ]]; then
        echo "Не удалось определить внешний IP сервера. Проверьте подключение к интернету."
        exit 1
    fi

    echo "Внешний IP сервера: $external_ip"

    # Получение A-записи домена
    domain_ip=$(dig +short A "$DOMAIN")

    # Проверка, что A-запись существует
    if [[ -z "$domain_ip" ]]; then
        echo "Не удалось получить A-запись для домена $DOMAIN."
        echo "Подробнее: https://wiki.yukikras.net/ru/selfsni"
        exit 1
    fi

    echo "A-запись домена $DOMAIN указывает на: $domain_ip"

    # Сравнение IP адресов
    if [[ "$domain_ip" == "$external_ip" ]]; then
        echo "A-запись домена соответствует внешнему IP сервера."
    else
        echo "A-запись домена не соответствует внешнему IP сервера."
        echo "Подробнее: https://wiki.yukikras.net/ru/selfsni#a-запись-домена-не-соответствует-внешнему-ip-сервера-или-не-удалось-получить-a-запись-для-домена"
        exit 1
    fi

else
    echo "Режим self-signed: проверки DNS и IP пропущены."
fi

export DOMAIN="$DOMAIN"
export SPORT="$SPORT"

# Проверка порта 443
if [[ $SELF_SIGNED -eq 0 ]]; then
    if ss -tuln | grep -q ":443 "; then
        echo "Порт 443 занят."
        echo "Подробнее: https://wiki.yukikras.net/ru/selfsni#порт-44380-занят-пожалуйста-освободите-порт"
        exit 1
    else
        echo "Порт 443 свободен."
    fi
else
    echo "Режим self-signed: проверка порта 443 пропущена."
fi

# Проверка порта 80
if [[ $WITHOUT_80 -eq 0 ]]; then
    if ss -tuln | grep -q ":80 "; then
        echo "Порт 80 занят."
        echo "Подробнее: https://wiki.yukikras.net/ru/selfsni"
        exit 1
    else
        echo "Порт 80 свободен."
    fi
else
    echo "Пропускаем настройку порта 80 (--without-80)."
fi

# Установка пакетов
apt update && apt install -y nginx certbot python3-certbot-nginx git openssl curl dnsutils

if [[ $? -ne 0 ]]; then
    echo "Ошибка установки пакетов."
    exit 1
fi

# Скачивание репозитория
TEMP_DIR=$(mktemp -d)

git clone https://github.com/learning-zone/website-templates.git "$TEMP_DIR"

if [[ $? -ne 0 ]]; then
    echo "Ошибка клонирования репозитория."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Выбор случайного сайта
SITE_DIR=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | shuf -n 1)

cp -r "$SITE_DIR"/* /var/www/html/

# Сертификаты
if [[ $SELF_SIGNED -eq 1 ]]; then

    echo "Генерируем self-signed сертификат..."

    mkdir -p /etc/letsencrypt/live/$DOMAIN

    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout /etc/letsencrypt/live/$DOMAIN/privkey.pem \
        -out /etc/letsencrypt/live/$DOMAIN/fullchain.pem \
        -subj "/CN=$DOMAIN"

    if [[ $? -ne 0 ]]; then
        echo "Ошибка генерации сертификата."
        exit 1
    fi

else

    if [[ $WITHOUT_80 -eq 1 ]]; then

        echo "Выпускаем сертификат через TLS-ALPN-01..."

        certbot certonly \
            --nginx \
            -d "$DOMAIN" \
            --agree-tos \
            -m "admin@$DOMAIN" \
            --non-interactive \
            --preferred-challenges tls-alpn-01

    else

        echo "Выпускаем сертификат через HTTP-01..."

        certbot --nginx \
            -d "$DOMAIN" \
            --agree-tos \
            -m "admin@$DOMAIN" \
            --non-interactive

    fi

    if [[ $? -ne 0 ]]; then
        echo "Ошибка выпуска сертификата."
        exit 1
    fi

fi

# Конфигурация nginx
cat > /etc/nginx/sites-enabled/sni.conf <<EOF
server {
EOF

if [[ $WITHOUT_80 -eq 0 ]]; then
cat >> /etc/nginx/sites-enabled/sni.conf <<EOF
    listen 80;
    server_name $DOMAIN;

    if (\$host = $DOMAIN) {
        return 301 https://\$host\$request_uri;
    }

    return 404;
EOF
fi

cat >> /etc/nginx/sites-enabled/sni.conf <<EOF
}

server {

    listen 127.0.0.1:$SPORT ssl http2 proxy_protocol;

    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;

    ssl_prefer_server_ciphers on;

    ssl_ciphers "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384";

    ssl_stapling on;
    ssl_stapling_verify on;

    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;

    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;

    location / {
        root /var/www/html;
        index index.html;
    }
}
EOF

# Удаление default конфига
rm -f /etc/nginx/sites-enabled/default

# Проверка nginx
nginx -t

if [[ $? -ne 0 ]]; then
    echo "Ошибка конфигурации nginx."
    exit 1
fi

# Перезапуск nginx
systemctl reload nginx

# Пути сертификатов
CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

echo ""
echo "======================================="
echo "SelfSNI успешно настроен"
echo "======================================="
echo ""
echo "Сертификат и ключ расположены в следующих путях:" 
echo "Сертификат: $CERT_PATH" 
echo "Ключ: $KEY_PATH"
echo ""
echo "В качестве Dest укажите: 127.0.0.1:$SPORT" 
echo "В качестве SNI укажите: $DOMAIN"
echo "Xver выставите на 1"
echo ""

# Удаление временной директории
rm -rf "$TEMP_DIR"

echo "Скрипт завершён."
