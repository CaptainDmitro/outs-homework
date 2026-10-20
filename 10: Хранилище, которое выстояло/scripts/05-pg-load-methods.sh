set -x
# dbgen создаёт файлы частей через open(O_CREAT) без mode: права случайные (lineitem.tbl.6 = ---x-----x)
chmod 644 $D/*.tbl*
ls -l $D/lineitem.tbl.6

psql -q -f /opt/bench/pg-schema.sql
psql -c '\dt'

# INSERT-скрипты из первых строк orders.tbl.1; один и тот же SQL потом пойдёт и в ClickHouse
gen_inserts() {
  awk -F'|' -v B="$1" '{
    gsub(/\047/, "\047\047")
    row = sprintf("(%s,%s,\047%s\047,%s,\047%s\047,\047%s\047,\047%s\047,%s,\047%s\047)", $1, $2, $3, $4, $5, $6, $7, $8, $9)
    printf "%s%s", ((NR - 1) % B ? "," : "INSERT INTO orders VALUES "), row
    if (NR % B == 0) print ";"
  } END { if (NR % B) print ";" }'
}
head -n 20000 $D/orders.tbl.1 | gen_inserts 1 > /data/ins_1x20k.sql
head -n 1000000 $D/orders.tbl.1 | gen_inserts 1000 > /data/ins_1000x1m.sql
head -2 /data/ins_1x20k.sql
ls -l /data/ins_*.sql

# 1. INSERT по одной строке, каждая в своей транзакции: 20 000 строк
time psql -q -f /data/ins_1x20k.sql
psql -c 'SELECT count(*) FROM orders'

# 2. INSERT по 1000 строк в одном операторе: 1 000 000 строк
psql -c 'TRUNCATE orders'
time psql -q -f /data/ins_1000x1m.sql
psql -c 'SELECT count(*) FROM orders'

# 3. COPY из файла на сервере, один поток: все 30 млн строк
psql -c 'TRUNCATE orders'
time (for f in $D/orders.tbl.*; do psql -qc "COPY orders FROM '$f' (DELIMITER '|')"; done)
psql -c 'SELECT count(*) FROM orders'

# 4. стриминг через клиента: cat | COPY FROM STDIN
psql -c 'TRUNCATE orders'
time (cat $D/orders.tbl.* | psql -qc "COPY orders FROM STDIN (DELIMITER '|')")
psql -c 'SELECT count(*) FROM orders'

# 5. сторонняя утилита pgloader
cat /opt/bench/orders.load
time pgloader /opt/bench/orders.load
psql -c 'SELECT count(*) FROM orders'

# 6. параллельный COPY: 8 сессий по одному файлу
psql -c 'TRUNCATE orders'
time (ls $D/orders.tbl.* | xargs -P 8 -I{} psql -qc "COPY orders FROM '{}' (DELIMITER '|')")
psql -c 'SELECT count(*) FROM orders'

# 7. стриминг прямо из генератора: dbgen -> FIFO -> sed -> COPY FROM STDIN, без файла на диске
mkdir -p /data/stream && cd /data/stream && rm -f customer.tbl && mkfifo customer.tbl
time (/opt/tpch-dbgen/dbgen -q -f -s $SF -T c & sed 's/|$//' customer.tbl | psql -qc "COPY customer FROM STDIN (DELIMITER '|')"; wait)
psql -c 'SELECT count(*) FROM customer'
