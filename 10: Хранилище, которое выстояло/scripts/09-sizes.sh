set -x
du -sh --apparent-size $D
du -sh /var/lib/postgresql/17/main/base /var/lib/postgresql/17/main/pg_wal
psql -c "SELECT c.relname AS table, c.reltuples::bigint AS rows,
                pg_size_pretty(pg_table_size(c.oid)) AS heap,
                pg_size_pretty(pg_indexes_size(c.oid)) AS indexes,
                pg_size_pretty(pg_total_relation_size(c.oid)) AS total
         FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind = 'r'
         ORDER BY pg_total_relation_size(c.oid) DESC"
psql -c "SELECT pg_size_pretty(pg_database_size('tpch'))"
clickhouse-client --format PrettyCompactMonoBlock -q "
  SELECT table, sum(rows) AS rows, count() AS parts,
         formatReadableSize(sum(data_compressed_bytes)) AS compressed,
         formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
         round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio
  FROM system.parts WHERE database = 'tpch' AND active
  GROUP BY table WITH TOTALS
  ORDER BY sum(data_compressed_bytes) DESC"
