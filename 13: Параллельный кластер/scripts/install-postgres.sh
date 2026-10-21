#!/bin/bash
# Одиночный PostgreSQL 16 (пакет Ubuntu 24.04) на ноде otus-yb-e, данные на /data/pg
set -xe
sudo apt-get -qq install -y postgresql-16 >/dev/null
sudo systemctl stop postgresql
sudo mkdir -p /data/pg && sudo chown postgres:postgres /data/pg
sudo -u postgres /usr/lib/postgresql/16/bin/initdb -D /data/pg/16 >/dev/null
sudo sed -i "s|^data_directory.*|data_directory = '/data/pg/16'|" /etc/postgresql/16/main/postgresql.conf
cat <<'C' | sudo tee /etc/postgresql/16/main/conf.d/otus.conf
shared_buffers = 2GB
effective_cache_size = 12GB
work_mem = 128MB
maintenance_work_mem = 1GB
max_wal_size = 2GB
max_parallel_workers_per_gather = 2
max_parallel_maintenance_workers = 2
random_page_cost = 1.1
jit = off
C
sudo systemctl start postgresql
sudo -u postgres psql -c "CREATE ROLE yb SUPERUSER LOGIN" -c "CREATE DATABASE tpch OWNER yb" -c "SHOW data_directory" -c "SELECT version()"
