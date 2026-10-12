#!/usr/bin/env bash
# Воспроизведение ДЗ №2 на чистой ВМ Debian 11 (bullseye) / arm64 или amd64.
# Запускать от пользователя с sudo. Для Ubuntu 20.04 замените в URL репозитория
# Docker "debian" на "ubuntu" и пропустите шаг 0.
set -euxo pipefail

PG_PASSWORD=${PG_PASSWORD:-otus_pass}

# 0. Bullseye снят с поддержки, пакеты переехали на archive.debian.org
sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
sudo tee /etc/apt/sources.list >/dev/null <<'SRC'
deb http://archive.debian.org/debian bullseye main
deb http://archive.debian.org/debian bullseye-updates main
deb http://archive.debian.org/debian-security bullseye-security main
SRC

# 1. Docker Engine из официального репозитория
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"   # вступит в силу после перелогина
sudo docker run --rm hello-world

# 2. Каталог для данных
sudo mkdir -p /var/lib/postgres

# 3. Сеть и сервер PostgreSQL 14
sudo docker network create pg-net || true
sudo docker run -d --name pg-server --network pg-net \
  -e POSTGRES_PASSWORD="$PG_PASSWORD" \
  -p 5432:5432 \
  -v /var/lib/postgres:/var/lib/postgresql/data \
  --restart unless-stopped \
  postgres:14
sleep 8

# 4-5. Клиент в отдельном контейнере, загрузка данных
sudo docker run --rm --network pg-net -e PGPASSWORD="$PG_PASSWORD" \
  -v "$PWD/shipments.sql:/tmp/shipments.sql:ro" postgres:14 \
  psql -h pg-server -U postgres -e -f /tmp/shipments.sql </dev/null

# 6. Пересоздание сервера и проверка
sudo docker rm -f pg-server
sudo docker run -d --name pg-server --network pg-net \
  -e POSTGRES_PASSWORD="$PG_PASSWORD" -p 5432:5432 \
  -v /var/lib/postgres:/var/lib/postgresql/data --restart unless-stopped postgres:14
sleep 5
sudo docker run --rm --network pg-net -e PGPASSWORD="$PG_PASSWORD" postgres:14 \
  psql -h pg-server -U postgres -c 'select * from shipments order by id;' </dev/null
