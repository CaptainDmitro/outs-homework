#!/bin/bash
# Прогоняет каждый запрос из каталога N раз и печатает время выполнения (мс) по \timing.
# bench.sh "<клиент psql/ysqlsh с параметрами>" <каталог с запросами> [N]
PSQL=$1 DIR=$2 N=${3:-3}
printf '%-18s' query; for i in $(seq $N); do printf '%14s' "run$i, ms"; done; echo
for q in $DIR/*.sql; do
  printf '%-18s' $(basename $q .sql)
  for i in $(seq $N); do
    t=$( { echo '\timing on'; cat $q; } | $PSQL -X -q -v ON_ERROR_STOP=1 -o /dev/null -f - 2>&1 | sed -n 's/^Time: \([0-9.]*\) ms.*/\1/p' | tail -1)
    printf '%14s' "${t:-ERROR}"
  done
  echo
done
