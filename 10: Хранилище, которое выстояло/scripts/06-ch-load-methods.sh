set -x
clickhouse-client --queries-file /opt/bench/ch-schema.sql
clickhouse-client -q 'SHOW TABLES FROM tpch'
CH="clickhouse-client -d tpch"

# 1. INSERT по одной строке, синхронно: тот же SQL, что и для PostgreSQL
time $CH --queries-file /data/ins_1x20k.sql
$CH -q 'SELECT count(), uniqExact(_part) AS parts FROM orders'

# 2. то же с async_insert: сервер сам копит строки в буфере и пишет пачками
$CH -q 'TRUNCATE orders'
time $CH --async_insert=1 --wait_for_async_insert=0 --queries-file /data/ins_1x20k.sql
$CH -q 'SYSTEM FLUSH ASYNC INSERT QUEUE'
$CH -q 'SELECT count(), uniqExact(_part) AS parts FROM orders'

# 3. INSERT по 1000 строк в одном операторе
$CH -q 'TRUNCATE orders'
time $CH --queries-file /data/ins_1000x1m.sql
$CH -q 'SELECT count() FROM orders'

# 4. стриминг через клиента, один поток: cat | INSERT FORMAT CSV
$CH -q 'TRUNCATE orders'
time (cat $D/orders.tbl.* | $CH --format_csv_delimiter='|' -q 'INSERT INTO orders FORMAT CSV')
$CH -q 'SELECT count() FROM orders'

# 5. забрать данные прямо из PostgreSQL табличной функцией postgresql()
$CH -q 'TRUNCATE orders'
time $CH -q "INSERT INTO orders SELECT * FROM postgresql('localhost:5432', 'tpch', 'orders', 'postgres', 'otus_pass')"
$CH -q 'SELECT count() FROM orders'

# 6. параллельно: 8 клиентов по одному файлу
$CH -q 'TRUNCATE orders'
time (ls $D/orders.tbl.* | xargs -P 8 -I{} sh -c "clickhouse-client -d tpch --format_csv_delimiter='|' -q 'INSERT INTO orders FORMAT CSV' < {}")
$CH -q 'SELECT count() FROM orders'

# 7. на стороне сервера: file() по маске читает файлы в несколько потоков
$CH -q 'TRUNCATE orders'
time $CH --max_insert_threads=8 --format_csv_delimiter='|' -q "INSERT INTO orders SELECT * FROM file('orders.tbl.*', CSV)"
$CH -q 'SELECT count() FROM orders'

# 8. стриминг прямо из генератора: dbgen -> FIFO -> sed -> clickhouse-client
mkdir -p /data/stream && cd /data/stream && rm -f customer.tbl && mkfifo customer.tbl
time (/opt/tpch-dbgen/dbgen -q -f -s $SF -T c & sed 's/|$//' customer.tbl | $CH --format_csv_delimiter='|' -q 'INSERT INTO customer FORMAT CSV'; wait)
$CH -q 'SELECT count() FROM customer'
