set -x
# холодный старт: вторая СУБД остановлена, кеш ОС сброшен, shared_buffers пустые
cold() {
  systemctl stop postgresql clickhouse-server
  sync && echo 3 > /proc/sys/vm/drop_caches
  systemctl start postgresql
  until pg_isready -q; do sleep 1; done
}
for q in q1-agg q2-filter q3-join; do
  cold
  for run in 1 2 3; do
    psql -X -P pager=off -c '\timing on' -f /opt/bench/$q.sql
  done
done
for q in q1-agg q2-filter q3-join; do
  { echo 'EXPLAIN (ANALYZE, BUFFERS)'; cat /opt/bench/$q.sql; } | psql -X -P pager=off
done
systemctl start clickhouse-server
