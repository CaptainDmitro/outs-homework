#!/bin/bash
# Узел кластера: etcd (DCS) + Patroni + PostgreSQL 16 в одном контейнере.
set -e
etcd --name "$PATRONI_NAME" --data-dir /var/lib/etcd/data \
  --listen-peer-urls http://0.0.0.0:2380 --listen-client-urls http://0.0.0.0:2379 \
  --initial-advertise-peer-urls "http://$NODE_IP:2380" --advertise-client-urls "http://$NODE_IP:2379" \
  --initial-cluster "$ETCD_CLUSTER" --initial-cluster-token "$PATRONI_SCOPE" --initial-cluster-state new &
mkdir -p /var/run/postgresql /var/lib/postgresql/16
chown -R postgres:postgres /var/run/postgresql /var/lib/postgresql
export PATRONI_RESTAPI_CONNECT_ADDRESS="$NODE_IP:8008"
export PATRONI_POSTGRESQL_CONNECT_ADDRESS="$NODE_IP:5432"
exec runuser -u postgres -- patroni /etc/patroni.yml
