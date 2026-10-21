#!/bin/bash
# Генерирует таблицы TPC-H через dbgen и сразу заливает их через COPY (dbgen пишет в FIFO, промежуточных файлов нет).
# tpch-load.sh "<клиент psql/ysqlsh с параметрами>" <SF> <число частей> <номер части> <таблица>...
set -e
PSQL=$1 SF=$2 CHUNKS=$3 STEP=$4
shift 4
declare -A FLAG=([lineitem]=L [orders]=O [customer]=c [part]=P [partsupp]=S [supplier]=s [nation]=n [region]=r)
cd ~/tpch-dbgen
for t in "$@"; do
  if [[ $t == nation || $t == region || $CHUNKS == 1 ]]; then f=$t.tbl; opts=""; else f=$t.tbl.$STEP; opts="-C $CHUNKS -S $STEP"; fi
  rm -f $f; mkfifo $f
  start=$(date +%s)
  ./dbgen -q -f -s $SF -T ${FLAG[$t]} $opts &
  sed 's/|$//' $f | $PSQL -v ON_ERROR_STOP=1 -c "COPY $t FROM STDIN WITH (DELIMITER '|')"
  wait
  rm -f $f
  echo "$(date +%T) $t part $STEP/$CHUNKS loaded in $(( $(date +%s) - start )) s"
done
