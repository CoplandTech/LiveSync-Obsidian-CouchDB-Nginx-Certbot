#!/bin/bash

# Прекращаем выполнение скрипта при ошибке
set -e

# Проверка наличия Docker
if ! command -v docker &> /dev/null; then
    echo "Ошибка: Docker не установлен. Пожалуйста, установите Docker и повторите попытку."
    exit 1
fi

# Проверка наличия Docker Compose
if ! command -v docker-compose &> /dev/null; then
    echo "Ошибка: Docker Compose не установлен. Пожалуйста, установите Docker Compose и повторите попытку."
    exit 1
fi

# Запрос данных у пользователя
read -p "Введите ваш домен (YOUR-DOMAIN): " DOMAIN
read -p "Введите имя пользователя CouchDB (YOUR-USER): " USER
read -sp "Введите пароль пользователя CouchDB (YOUR-PASS): " PASS
echo

# Создание необходимых директорий и файлов
mkdir -p couchdb/certbot/conf couchdb/certbot/www/.well-known/acme-challenge couchdb/data couchdb/conf

# Создание файла nginx.conf до получения SSL
cat <<EOL > couchdb/nginx.conf
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
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
cat <<EOL > couchdb/docker-compose.yml
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
      - ./data/couchdb:/opt/couchdb/data
      - ./conf/local.ini:/opt/couchdb/etc/local.ini

  nginx:
    image: nginx:latest
    container_name: nginx
    restart: always
    ports:
      - 80:80
      - 443:443
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/html
    depends_on:
      - couchdb

  certbot:
    image: certbot/certbot
    container_name: certbot
    restart: always
    volumes:
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/html
    entrypoint: /bin/sh -c 'trap exit TERM; while :; do sleep 6h & wait \$${!}; certbot renew; done'
EOL

# Создание файла local.ini
cat <<EOL > couchdb/conf/local.ini
[couchdb]
single_node=true
max_document_size = 50000000

[chttpd]
require_valid_user = true
max_http_request_size = 4294967296

[chttpd_auth]
require_valid_user = true
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
cd couchdb
docker-compose up -d nginx

# Получение SSL сертификата
docker run -it --rm \
  -v $(pwd)/couchdb/certbot/conf:/etc/letsencrypt \
  -v $(pwd)/couchdb/certbot/www:/var/www/html \
  certbot/certbot certonly --dry-run \
  --webroot-path=/var/www/html \
  -d $DOMAIN

# Проверка успешности получения сертификата
if [ -d "couchdb/certbot/conf/live/$DOMAIN" ]; then
    echo "SSL сертификат успешно получен. Добавляем конфигурацию SSL в nginx.conf."

    cat <<EOL >> couchdb/nginx.conf

server {
    listen 443 ssl;
    server_name $DOMAIN;

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
cd couchdb
docker-compose up --build -d

echo "Скрипт успешно выполнен."
