#!/bin/bash

# Прекращаем выполнение скрипта при ошибке
set -e
#!/bin/bash

# Функция для проверки наличия команды
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Проверка установки Docker
if ! command_exists docker; then
    echo "Docker не установлен. Устанавливаем Docker..."
    sudo apt-get update
    sudo apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
    echo "Docker уже установлен."
fi

# Проверка установки Docker Compose
if ! command_exists docker-compose; then
    echo "Docker Compose не установлен. Устанавливаем Docker Compose..."
    sudo curl -L "https://github.com/docker/compose/releases/download/$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
else
    echo "Docker Compose уже установлен."
fi

# Запрос данных у пользователя
read -p "Enter your DOMAIN: " DOMAIN
read -p "Enter username CouchDB: " USER
read -sp "Enter password CouchDB: " PASS
echo

# Создание необходимых директорий и файлов
mkdir -p /opt/LiveSync-CouchDB/nginx/www/$DOMAIN/.well-known/acme-challenge/ /opt/LiveSync-CouchDB/nginx/certbot /opt/LiveSync-CouchDB/couchdb/data /opt/LiveSync-CouchDB/couchdb/conf

# Создание файла nginx.conf до получения SSL
cat <<EOL > /opt/LiveSync-CouchDB/nginx/nginx.conf
server {
    listen 80;
    server_name $DOMAIN;

    root /var/www/$DOMAIN;
	
    location /.well-known/acme-challenge/ {
        root /var/www/$DOMAIN;
        allow all;
    }

    location / {
        proxy_pass http://couchdb:5984;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

# Создание файла docker-compose.yml
cat <<EOL > /opt/LiveSync-CouchDB/docker-compose.yml
version: '3.1'

services:
  couchdb:
    image: couchdb:latest
    container_name: couchdb
    restart: always
    ports:
      - 5984:5984
    environment:
      - COUCHDB_USER=$USER
      - COUCHDB_PASSWORD=$PASS
    volumes:
      - /opt/LiveSync-CouchDB/couchdb/data/:/opt/couchdb/data
      - /opt/LiveSync-CouchDB/couchdb/conf/local.ini:/opt/couchdb/etc/local.ini

  nginx:
    image: nginx:latest
    container_name: nginx
    restart: always
    ports:
      - 80:80
      - 443:443
    volumes:
      - /opt/LiveSync-CouchDB/nginx/nginx.conf:/etc/nginx/conf.d/default.conf
      - /opt/LiveSync-CouchDB/nginx/certbot/conf:/etc/letsencrypt
      - /opt/LiveSync-CouchDB/nginx/www:/var/www/
    depends_on:
      - couchdb

  certbot:
    image: certbot/certbot
    container_name: certbot
    restart: always
    volumes:
      - /opt/LiveSync-CouchDB/nginx/certbot/conf:/etc/letsencrypt
      - /opt/LiveSync-CouchDB/nginx/www:/var/www/
    entrypoint: /bin/sh -c 'trap exit TERM; while :; do sleep 6h & wait $${!}; certbot renew; done'
EOL

# Создание файла local.ini
cat <<EOL > /opt/LiveSync-CouchDB/couchdb/conf/local.ini
[couchdb]
single_node=true
max_document_size = 50000000

[chttpd]
require_valid_admin = true
max_http_request_size = 4294967296

[chttpd_auth]
require_valid_admin = true
authentication_redirect = /_utils/session.html

[httpd]
WWW-Authenticate = Basic realm="couchdb"
enable_cors = true

[cors]
origins = app://obsidian.md,capacitor://localhost,http://localhost
credentials = true
headers = accept, authorization, content-type, origin, referer
methods = GET, PUT, POST, HEAD, DELETE
max_age = 3600
EOL

# Запуск nginx перед получением SSL сертификата
cd /opt/LiveSync-CouchDB/
docker-compose up -d nginx

# Получение SSL сертификата
docker run -it --rm \
-v /opt/LiveSync-CouchDB/nginx/certbot/conf:/etc/letsencrypt \
  -v /opt/LiveSync-CouchDB/nginx/www/$DOMAIN:/var/www/$DOMAIN \
  certbot/certbot certonly --webroot \
  -w /var/www/$DOMAIN \
  -d $DOMAIN

# Проверка успешности получения сертификата
if [ -d "/opt/LiveSync-CouchDB/nginx/certbot/conf/live/$DOMAIN" ]; then
    echo "SSL сертификат успешно получен. Добавляем конфигурацию SSL в nginx.conf."

    cat <<EOL >> /opt/LiveSync-CouchDB/nginx/nginx.conf

server {
    listen 443 ssl;
    server_name $DOMAIN;

    root /var/www/$DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-CCM:ECDHE-RSA-AES256-CCM:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES128-SHA:RSA-AES128-SHA:RSA-AES256-SHA';
    ssl_prefer_server_ciphers off;
    ssl_ecdh_curve X25519:P-256:P-384;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;

    location / {
        proxy_pass http://couchdb:5984;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL
else
    echo "Ошибка: SSL сертификат не был получен."
    exit 1
fi

# Запуск docker-compose
cd /opt/LiveSync-CouchDB/
docker-compose up --build -d

echo "Скрипт успешно выполнен."
