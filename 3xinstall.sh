#!/bin/bash

INSTALL_WARP=false
EXTENDED_SETUP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --warp)
            INSTALL_WARP=true
            shift
            ;;
        --extend)
            EXTENDED_SETUP=true
            shift
            ;;
        *)
            echo "Неизвестный аргумент: $1" >&3
            exit 1
            ;;
    esac
done

# Проверяем наличие команды x-ui
if command -v x-ui &> /dev/null; then
    echo "Обнаружена установленная панель x-ui."

    # Запрос у пользователя на переустановку
    read -p "Вы хотите переустановить x-ui? [y/N]: " confirm
    confirm=${confirm,,}  # перевод в нижний регистр

    if [[ "$confirm" != "y" && "$confirm" != "yes" ]]; then
        echo "Отмена. Скрипт завершает работу."
        exit 1
    fi

    echo "Удаление x-ui..."
    # Тихое удаление x-ui (если установлен через официальный скрипт)
    /usr/local/x-ui/x-ui uninstall -y &>/dev/null || true
    rm -rf /usr/local/x-ui /etc/x-ui /usr/bin/x-ui /etc/systemd/system/x-ui.service
    systemctl daemon-reexec
    systemctl daemon-reload
    rm /root/3x-ui.txt
    echo "x-ui успешно удалена. Продолжаем выполнение скрипта..."
fi

# Вывод всех команд кроме диалога — в лог
exec 3>&1  # Сохраняем stdout для сообщений пользователю
LOG_FILE="/var/log/3x-ui_install_log.txt"
exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# === Порт панели: по умолчанию 8080, а при аргументе extend — ручной выбор ===
if [[ "$EXTENDED_SETUP" == true ]]; then
    read -rp $'\033[0;33mВведите порт для панели (Enter для 8080): \033[0m' USER_PORT
    PORT=${USER_PORT:-8080}

    # === Вопрос о SelfSNI ===
    echo -e "\n${yellow}Хотите установить SelfSNI (поддельный сайт для маскировки)?${plain}"
    read -rp $'\033[0;36mВведите y для установки или нажмите Enter для пропуска: \033[0m' INSTALL_SELFSNI
    if [[ "$INSTALL_SELFSNI" == "y" || "$INSTALL_SELFSNI" == "Y" ]]; then
        echo -e "${green}Устанавливается SelfSNI...${plain}" >&3
        bash <(curl -Ls https://raw.githubusercontent.com/YukiKras/vless-scripts/refs/heads/main/fakesite.sh)
    else
        echo -e "${yellow}Установка SelfSNI пропущена.${plain}" >&3
    fi
else
    PORT=8080
    echo -e "${yellow}Порт панели не указан, используется по умолчанию: ${PORT}${plain}" >&3
fi

echo -e "Весь процесс установки будет сохранён в файле: \033[0;36m${LOG_FILE}\033[0m" >&3
echo -e "\n\033[1;34mИдёт установка... Пожалуйста, не закрывайте терминал.\033[0m"

# Генерация
gen_random_string() {
    local length="$1"
    LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$length" | head -n 1
}
USERNAME=$(gen_random_string 10)
PASSWORD=$(gen_random_string 10)
WEBPATH=$(gen_random_string 18)

# Проверка root
if [[ $EUID -ne 0 ]]; then
    echo -e "${red}Ошибка:${plain} скрипт нужно запускать от root" >&3
    exit 1
fi

# Определение ОС
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
else
    echo "Не удалось определить ОС" >&3
    exit 1
fi

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | arm64 | aarch64) echo 'arm64' ;;
        armv7* | arm) echo 'armv7' ;;
        armv6*) echo 'armv6' ;;
        armv5*) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo "unknown" ;;
    esac
}
ARCH=$(arch)

# Установка зависимостей
case "${release}" in
    ubuntu | debian | armbian)
        apt-get update > /dev/null 2>&1
        apt-get install -y -q wget curl tar tzdata jq xxd qrencode > /dev/null 2>&1
        ;;
    centos | rhel | almalinux | rocky | ol)
        yum -y update > /dev/null 2>&1
        yum install -y -q wget curl tar tzdata jq xxd qrencode > /dev/null 2>&1
        ;;
    fedora | amzn | virtuozzo)
        dnf -y update > /dev/null 2>&1
        dnf install -y -q wget curl tar tzdata jq xxd qrencode > /dev/null 2>&1
        ;;
    arch | manjaro | parch)
        pacman -Syu --noconfirm > /dev/null 2>&1
        pacman -S --noconfirm wget curl tar tzdata jq xxd qrencode > /dev/null 2>&1
        ;;
    opensuse-tumbleweed)
        zypper refresh > /dev/null 2>&1
        zypper install -y wget curl tar timezone jq xxd qrencode > /dev/null 2>&1
        ;;
    *)
        apt-get update > /dev/null 2>&1
        apt-get install -y wget curl tar tzdata jq xxd qrencode > /dev/null 2>&1
        ;;
esac

# Установка x-ui
cd /usr/local/ || exit 1
URL1="https://github.com/MHSanaei/3x-ui/releases/download/v2.6.7/x-ui-linux-amd64.tar.gz"
URL2="https://files.yukikras.net/3x-ui/v2.6.7.x-ui-linux-amd64.tar.gz"
FILE="x-ui-linux-${ARCH}.tar.gz"

if ! wget -q -O "$FILE" "$URL1"; then
    echo "Не удалось скачать с GitHub, пробую зеркало..."
    wget -q -O "$FILE" "$URL2" || {
        echo "Ошибка: не удалось скачать файл ни с одного источника"
        exit 1
    }
fi

systemctl stop x-ui 2>/dev/null
rm -rf /usr/local/x-ui/
tar -xzf x-ui-linux-${ARCH}.tar.gz
rm -f x-ui-linux-${ARCH}.tar.gz

cd x-ui || exit 1
chmod +x x-ui
[[ "$ARCH" == armv* ]] && mv bin/xray-linux-${ARCH} bin/xray-linux-arm && chmod +x bin/xray-linux-arm
chmod +x x-ui bin/xray-linux-${ARCH}
cp -f x-ui.service /etc/systemd/system/
URL1="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh"
URL2="https://files.yukikras.net/3x-ui/x-ui.sh"
FILE="/usr/bin/x-ui"

if ! wget -q -O "$FILE" "$URL1"; then
    echo "Не удалось скачать с GitHub, пробую зеркало..."
    wget -q -O "$FILE" "$URL2" || {
        echo "Ошибка: не удалось скачать файл ни с одного источника"
        exit 1
    }
fi
chmod +x /usr/local/x-ui/x-ui.sh /usr/bin/x-ui

# Настройка
/usr/local/x-ui/x-ui setting -username "$USERNAME" -password "$PASSWORD" -port "$PORT" -webBasePath "$WEBPATH" >>"$LOG_FILE" 2>&1
/usr/local/x-ui/x-ui migrate >>"$LOG_FILE" 2>&1

systemctl daemon-reload >>"$LOG_FILE" 2>&1
systemctl enable x-ui >>"$LOG_FILE" 2>&1
systemctl start x-ui >>"$LOG_FILE" 2>&1

# Генерация Reality ключей
KEYS=$(/usr/local/x-ui/bin/xray-linux-${ARCH} x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep -i "Private" | sed -E 's/.*Key:\s*//')
PUBLIC_KEY=$(echo "$KEYS" | grep -i "Password" | sed -E 's/.*Password:\s*//')
SHORT_ID=$(head -c 8 /dev/urandom | xxd -p)
UUID=$(cat /proc/sys/kernel/random/uuid)
EMAIL=$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)

echo -e "${green}Запуск SelfSNI с автоматической генерацией домена...${plain}" >&3
SELFSNI_OUTPUT=$(bash <(curl -Ls https://raw.githubusercontent.com/YukiKras/vless-scripts/refs/heads/main/fakesite.sh) --without-80 --self-signed --rand-dns 2>&1)
# Извлекаем домен и порт из вывода (хрупкий парсинг)
DOMAIN=$(echo "$SELFSNI_OUTPUT" | grep "В качестве SNI укажите:" | head -1 | awk '{print $NF}')
SPORT=$(echo "$SELFSNI_OUTPUT" | grep "В качестве Dest укажите:" | head -1 | awk -F: '{print $NF}')
if [[ -z "$DOMAIN" || -z "$SPORT" ]]; then
    echo -e "${red}Не удалось извлечь DOMAIN/SPORT из вывода SelfSNI.${plain}" >&3
    exit 1
fi
DEST="127.0.0.1:${SPORT}"
SNI="$DOMAIN"
XVER=1
echo -e "${green}SelfSNI завершён: Dest=${DEST}, SNI=${SNI}${plain}" >&3

# === Аутентификация в x-ui API ===
COOKIE_JAR=$(mktemp)

# === Авторизация через cookie ===
LOGIN_RESPONSE=$(curl -s -c "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${WEBPATH}/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"${USERNAME}\", \"password\": \"${PASSWORD}\"}")

if ! echo "$LOGIN_RESPONSE" | grep -q '"success":true'; then
    echo -e "${red}Ошибка авторизации через cookie.${plain}" >&3
    echo "$LOGIN_RESPONSE" >&3
    exit 1
fi

# === Формирование JSON ===
SETTINGS_JSON=$(jq -nc --arg uuid "$UUID" --arg email "$EMAIL" '{
  clients: [
    {
      id: $uuid,
      flow: "xtls-rprx-vision",
      email: $email,
      enable: true
    }
  ],
  decryption: "none"
}')

FINGERPRINTS=("firefox" "ios" "safari" "android" "edge" "qq")
FINGERPRINT=${FINGERPRINTS[$((RANDOM % ${#FINGERPRINTS[@]}))]}

STREAM_SETTINGS_JSON=$(jq -nc --arg pbk "$PUBLIC_KEY" --arg prk "$PRIVATE_KEY" --arg sid "$SHORT_ID" --arg dest "$DEST" --arg sni "$SNI" --argjson xver "$XVER" --arg fingerprint "$FINGERPRINT" '{
  network: "tcp",
  security: "reality",
  realitySettings: {
    show: false,
    dest: $dest,
    xver: $xver,
    serverNames: [$sni],
    privateKey: $prk,
    settings: {publicKey: $pbk, fingerprint: $fingerprint},
    shortIds: [$sid]
  }
}')

SNIFFING_JSON=$(jq -nc '{
  enabled: true,
  destOverride: ["http", "tls"]
}')

# === Отправка инбаунда через API с cookie ===
ADD_RESULT=$(curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${WEBPATH}/panel/api/inbounds/add" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc \
    --argjson settings "$SETTINGS_JSON" \
    --argjson stream "$STREAM_SETTINGS_JSON" \
    --argjson sniffing "$SNIFFING_JSON" \
    '{
      enable: true,
      remark: "reality443-auto",
      listen: "",
      port: 443,
      protocol: "vless",
      settings: ($settings | tostring),
      streamSettings: ($stream | tostring),
      sniffing: ($sniffing | tostring)
    }')"
)

# Проверка
if echo "$ADD_RESULT" | grep -q '"success":true'; then
    echo -e "${green}Инбаунд успешно добавлен через API.${plain}" >&3

    # Перезапуск x-ui
    systemctl restart x-ui >>"$LOG_FILE" 2>&1

    if [[ "$INSTALL_WARP" == true ]]; then
        echo -e "${yellow}Установка WARP...${plain}" >&3
        wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh -O /tmp/warp_menu.sh >/dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            echo -e "${green}Скрипт WARP загружен, начинаем установку...${plain}" >&3
            echo -e "1\n" | bash /tmp/warp_menu.sh c >/dev/null 2>&1
            if [[ $? -eq 0 ]]; then
                echo -e "${green}WARP успешно установлен${plain}" >&3
                
                echo -e "${yellow}Настройка WARP в 3x-ui панели...${plain}" >&3
                
                XRAY_CONFIG='{
      "log": {
        "access": "none",
        "dnsLog": false,
        "error": "",
        "loglevel": "warning",
        "maskAddress": ""
      },
      "api": {
        "tag": "api",
        "services": [
          "HandlerService",
          "LoggerService",
          "StatsService"
        ]
      },
      "inbounds": [
        {
          "tag": "api",
          "listen": "127.0.0.1",
          "port": 62789,
          "protocol": "dokodemo-door",
          "settings": {
            "address": "127.0.0.1"
          }
        }
      ],
      "outbounds": [
        {
          "tag": "direct",
          "protocol": "freedom",
          "settings": {
            "domainStrategy": "AsIs",
            "redirect": "",
            "noises": []
          }
        },
        {
          "tag": "blocked",
          "protocol": "blackhole",
          "settings": {}
        },
        {
          "tag": "WARP",
          "protocol": "socks",
          "settings": {
            "servers": [
              {
                "address": "127.0.0.1",
                "port": 40000,
                "users": []
              }
            ]
          }
        }
      ],
      "policy": {
        "levels": {
          "0": {
            "statsUserDownlink": true,
            "statsUserUplink": true
          }
        },
        "system": {
          "statsInboundDownlink": true,
          "statsInboundUplink": true,
          "statsOutboundDownlink": false,
          "statsOutboundUplink": false
        }
      },
      "routing": {
        "domainStrategy": "AsIs",
        "rules": [
          {
            "type": "field",
            "inboundTag": [
              "api"
            ],
            "outboundTag": "api"
          },
          {
            "type": "field",
            "outboundTag": "blocked",
            "ip": [
              "geoip:private"
            ]
          },
          {
            "type": "field",
            "outboundTag": "blocked",
            "protocol": [
              "bittorrent"
            ]
          },
          {
            "type": "field",
            "inboundTag": [
              "inbound-443"
            ],
            "outboundTag": "WARP"
          }
        ]
      },
      "stats": {},
      "metrics": {
        "tag": "metrics_out",
        "listen": "127.0.0.1:11111"
      }
    }'
                
                XRAY_CONFIG_ENCODED=$(echo "$XRAY_CONFIG" | jq -sRr @uri)
                
                echo -e "${yellow}Отправка конфигурации Xray...${plain}" >&3
                UPDATE_RESPONSE=$(curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${WEBPATH}/panel/xray/update" \
                  -H "Content-Type: application/x-www-form-urlencoded" \
                  --data-raw "xraySetting=${XRAY_CONFIG_ENCODED}")
                
                if echo "$UPDATE_RESPONSE" | grep -q '"success":true'; then
                    echo -e "${green}Конфигурация Xray успешно обновлена${plain}" >&3
                    
                    echo -e "${yellow}Перезапуск Xray...${plain}" >&3
                    RESTART_RESPONSE=$(curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:${PORT}/${WEBPATH}/server/restartXrayService")
                    
                    if echo "$RESTART_RESPONSE" | grep -q '"success":true'; then
                        echo -e "${green}Xray успешно перезапущен с настройками WARP${plain}" >&3
                        
                        echo -e "\n${green}VLESS Reality с поддержкой WARP успешно настроен!${plain}" >&3
                        echo -e "${yellow}Примечание: Весь трафик через Reality инбаунд теперь будет идти через WARP${plain}" >&3
                    else
                        echo -e "${red}Ошибка при перезапуске Xray:${plain}" >&3
                        echo "$RESTART_RESPONSE" >&3
                    fi
                else
                    echo -e "${red}Ошибка при обновлении конфигурации Xray:${plain}" >&3
                    echo "$UPDATE_RESPONSE" >&3
                fi
            else
                echo -e "${red}Ошибка при установке WARP${plain}" >&3
            fi
            rm -f /tmp/warp_menu.sh
        else
            echo -e "${red}Не удалось загрузить скрипт WARP${plain}" >&3
        fi
    fi
    
    rm -f "$COOKIE_JAR"

    SERVER_IP=$(curl -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 https://4.ident.me)
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:443?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${SNI}&allowInsecure=true&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2F#${EMAIL}"

    echo -e ""
    echo -e "\n\033[0;32mVLESS Reality успешно создан!\033[0m" >&3
    echo -e "\033[1;36mВаш VPN ключ, его можно использовать сразу на нескольких устройствах:\033[0m" >&3
    echo -e ""
    echo -e "${VLESS_LINK}" >&3
    echo -e ""
    echo -e "QR код с Vless ключом, вы сможете отсканировать его с телефона в Happ"
    echo -e ""
    qrencode -t ANSIUTF8 "$VLESS_LINK"
    echo -e ""
    echo -e "С инструкцией по созданию дополнительных Vless ключей вы можете ознакомиться тут: https://wiki.yukikras.net/ru/razvertyvanie-proksi-protokola-vless-s-pomoshyu-3x-ui#как-добавлять-новых-клиентов"
    echo -e ""
    echo -e "Если у вас не открывается 3x-ui панель, попробуйте, пожалуйста её открыть следуя этой инструкции: https://github.com/YukiKras/wiki/blob/main/ssh-tunnels.md"

    {
    echo "Ваш VPN ключ, его можно использовать сразу на нескольких устройствах:"
    echo ""
    echo "$VLESS_LINK"
    echo ""
    echo "QR код с Vless ключом, вы сможете отсканировать его с телефона в Happ"
    echo ""
    qrencode -t ANSIUTF8 "$VLESS_LINK"
    echo ""
    echo "С инструкцией по созданию дополнительных Vless ключей вы можете ознакомиться тут: https://wiki.yukikras.net/ru/razvertyvanie-proksi-protokola-vless-s-pomoshyu-3x-ui#как-добавлять-новых-клиентов"
    echo ""
    echo -e "Если у вас не открывается 3x-ui панель, попробуйте, пожалуйста её открыть следуя этой инструкции: https://github.com/YukiKras/wiki/blob/main/ssh-tunnels.md"
    } >> /root/3x-ui.txt
else
    echo -e "${red}Ошибка при добавлении инбаунда через API:${plain}" >&3
    echo "$ADD_RESULT" >&3
fi

# === Общая финальная информация (всегда выводится) ===
SERVER_IP=${SERVER_IP:-$(curl -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 https://4.ident.me)}

echo -e "\n\033[1;32mПанель управления 3X-UI доступна по следующим данным:\033[0m" >&3
echo -e "Адрес панели: \033[1;36mhttp://${SERVER_IP}:${PORT}/${WEBPATH}\033[0m" >&3
echo -e "Логин:        \033[1;33m${USERNAME}\033[0m" >&3
echo -e "Пароль:       \033[1;33m${PASSWORD}\033[0m" >&3

echo -e "\nИнструкции по настройке VPN приложений вы сможете найти здесь:" >&3
echo -e "\033[1;34mhttps://github.com/YukiKras/wiki/blob/main/nastroikavpn.md\033[0m" >&3

echo -e "\nВсе данные сохранены в файл: \033[1;36m/root/3x-ui.txt\033[0m" >&3
echo -e "Для повторного просмотра информации используйте команду:" >&3
echo -e "" >&3
echo -e "\033[0;36mcat /root/3x-ui.txt\033[0m" >&3
echo -e "" >&3

{
  echo "Панель управления 3X-UI доступна по следующим данным:"
  echo "Адрес панели - http://${SERVER_IP}:${PORT}/${WEBPATH}"
  echo "Логин:         ${USERNAME}"
  echo "Пароль:        ${PASSWORD}"
  echo ""
  echo "Инструкции по настройке VPN приложений:"
  echo "https://github.com/YukiKras/wiki/blob/main/nastroikavpn.md"
} >> /root/3x-ui.txt
