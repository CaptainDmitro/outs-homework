set -x
CH="clickhouse-client -d tpch"
# фоновые слияния после загрузки должны закончиться до замеров
until [ "$($CH -q 'SELECT count() FROM system.merges')" = 0 ]; do sleep 10; done
# холодный старт: вторая СУБД остановлена, кеш ОС сброшен, кеши ClickHouse пустые после рестарта
cold() {
  systemctl stop postgresql clickhouse-server
  sync && echo 3 > /proc/sys/vm/drop_caches
  systemctl start clickhouse-server
  until $CH -q 'SELECT 1' >/dev/null 2>&1; do sleep 1; done
}
for q in q1-agg q2-filter q3-join; do
  cold
  for run in 1 2 3; do
    $CH --time --format PrettyCompactMonoBlock --queries-file /opt/bench/$q.sql
  done
done
for q in q1-agg q2-filter q3-join; do
  $CH -q "EXPLAIN indexes = 1 $(sed 's/;$//' /opt/bench/$q.sql)"
done
$CH -q 'SYSTEM FLUSH LOGS'
$CH --format PrettyCompactMonoBlock -q "
  SELECT event_time, query_duration_ms AS ms, read_rows, formatReadableSize(read_bytes) AS read,
         formatReadableSize(memory_usage) AS memory, substring(replaceAll(query, '\n', ' '), 1, 40) AS query
  FROM system.query_log
  WHERE type = 'QueryFinish' AND query_kind = 'Select' AND query LIKE '%FROM lineitem%' AND event_time > now() - INTERVAL 1 HOUR
  ORDER BY event_time"
systemctl start postgresql
