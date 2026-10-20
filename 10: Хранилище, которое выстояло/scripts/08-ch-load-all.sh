set -x
CH="clickhouse-client -d tpch"
# остальные таблицы: INSERT ... SELECT FROM file() на сервере, 8 потоков вставки
time (for t in lineitem partsupp part supplier nation region; do
  $CH --max_insert_threads=8 --format_csv_delimiter='|' -q "INSERT INTO $t SELECT * FROM file('$t.tbl*', CSV)"
done)
$CH -q "SELECT table, count() AS parts, sum(rows) AS rows FROM system.parts WHERE database = 'tpch' AND active GROUP BY table ORDER BY rows DESC" --format PrettyCompactMonoBlock
