#!/bin/bash
# Раз в секунду пишет строку в кластер через балансировщик и печатает, кто её принял.
# Адрес: PGHOST (по умолчанию DNS-имя внутри VPC) или первый аргумент.
export PGHOST=${1:-${PGHOST:-pg.bananaflow.internal}} PGPORT=5432 PGUSER=banana PGPASSWORD=banana_pass_11 PGDATABASE=bananaflow PGCONNECT_TIMEOUT=2
while true; do
  r=$(psql -XAtq -c "insert into ha_test(cluster, node) values (current_setting('cluster_name'), inet_server_addr()) returning id, cluster, node" 2>&1 | head -1)
  echo "$(date +%T) $r"
  sleep 1
done
