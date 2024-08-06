#!/bin/bash

# Прекращаем выполнение скрипта при ошибке
set -e

# Проверка наличия sudo прав
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or use sudo"
  exit 1
fi

# Функция для проверки наличия команды
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Проверка установки Docker
if ! command_exists docker; then
    echo "Docker is not installed. Installing Docker..."
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
    echo "Docker is already installed."
fi

# Проверка установки Docker Compose
if ! command_exists docker-compose; then
    echo "Docker Compose is not installed. Installing Docker Compose..."
    sudo curl -L "https://github.com/docker/compose/releases/download/$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
else
    echo "Docker Compose is already installed."
fi

# Запрос данных у пользователя
read -p "Enter username CouchDB: " USER
read -sp "Enter password CouchDB: " PASS
echo
read -p "Enter the full path (/DIR_PATH/LiveSync-CouchDB/) to the directory: " DIR_PATH
read -p "Enter your DOMAIN: " DOMAIN
read -p "Do you want to set up SSL? (yes/no): " SSL_SETUP

# Создание необходимых директорий и файлов
mkdir -p $DIR_PATH/LiveSync-CouchDB/nginx/www/$DOMAIN/.well-known/acme-challenge/ $DIR_PATH/LiveSync-CouchDB/nginx/certbot $DIR_PATH/LiveSync-CouchDB/couchdb/data $DIR_PATH/LiveSync-CouchDB/couchdb/conf

# Создание файла nginx.conf до получения SSL
cat <<EOL > $DIR_PATH/LiveSync-CouchDB/nginx/nginx.conf
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
cat <<EOL > $DIR_PATH/LiveSync-CouchDB/docker-compose.yml
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
      - $DIR_PATH/LiveSync-CouchDB/couchdb/data/:/opt/couchdb/data
      - $DIR_PATH/LiveSync-CouchDB/couchdb/conf/local.ini:/opt/couchdb/etc/local.ini

  nginx:
    image: nginx:latest
    container_name: nginx
    restart: always
    ports:
      - 80:80
      - 443:443
    volumes:
      - $DIR_PATH/LiveSync-CouchDB/nginx/nginx.conf:/etc/nginx/conf.d/default.conf
      - $DIR_PATH/LiveSync-CouchDB/nginx/certbot/conf:/etc/letsencrypt
      - $DIR_PATH/LiveSync-CouchDB/nginx/www:/var/www/
    depends_on:
      - couchdb

EOL

# Добавляем certbot сервис только если SSL_SETUP равно "yes"
if [ "$SSL_SETUP" == "yes" ]; then
    cat <<EOL >> $DIR_PATH/LiveSync-CouchDB/docker-compose.yml
  certbot:
    image: certbot/certbot
    container_name: certbot
    restart: always
    volumes:
      - $DIR_PATH/LiveSync-CouchDB/nginx/certbot/conf:/etc/letsencrypt
      - $DIR_PATH/LiveSync-CouchDB/nginx/www:/var/www/
    entrypoint: /bin/sh -c 'trap exit TERM; while :; do sleep 6h & wait $${!}; certbot renew; done'
EOL
fi

# Создание файла local.ini
cat <<EOL > $DIR_PATH/LiveSync-CouchDB/couchdb/conf/local.ini
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
cd $DIR_PATH/LiveSync-CouchDB/
docker-compose up -d nginx

if [ "$SSL_SETUP" == "yes" ]; then
    read -p "How many hours between SSL checks? (e.g., 24 for 1 day, 168 for 7 days, 336 for 14 days): " SSL_HOURS

    docker run -it --rm \
    -v $DIR_PATH/LiveSync-CouchDB/nginx/certbot/conf:/etc/letsencrypt \
    -v $DIR_PATH/LiveSync-CouchDB/nginx/www/$DOMAIN:/var/www/$DOMAIN \
    certbot/certbot certonly --webroot \
    -w /var/www/$DOMAIN \
    -d $DOMAIN

    # Проверка успешности получения сертификата
    if [ -d "$DIR_PATH/LiveSync-CouchDB/nginx/certbot/conf/live/$DOMAIN" ]; then
        echo "The SSL certificate has been successfully received. Adding the SSL configuration to nginx.conf."

        # Очистка файла nginx.conf
        > $DIR_PATH/LiveSync-CouchDB/nginx/nginx.conf

        cat <<EOL >> $DIR_PATH/LiveSync-CouchDB/nginx/nginx.conf

server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://$host$request_uri;

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
        # Перезапуск nginx
        docker-compose restart nginx
    else
        echo "Error: The SSL certificate was not received."
        echo "The contents of the directory $DIR_PATH/LiveSync-CouchDB/nginx/certbot/conf:"
        ls -la $DIR_PATH/LiveSync-CouchDB/nginx/certbot/conf
        exit 1
    fi

    # Обновление интервала проверки SSL
    sed -i "s/sleep 6h/sleep ${SSL_HOURS}h/" $DIR_PATH/LiveSync-CouchDB/docker-compose.yml
fi

# Запуск docker-compose без certbot, если SSL_SETUP равно "no"
if [ "$SSL_SETUP" == "no" ]; then
    docker-compose up --build -d couchdb nginx
else
    docker-compose up --build -d
fi

echo "The script was executed successfully."
