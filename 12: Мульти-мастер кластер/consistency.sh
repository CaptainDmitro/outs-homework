#!/bin/bash
# Запись через один узел и немедленное чтение через другой: ./consistency.sh N URL URL URL
n=$1
shift
urls=("$@")
psql "${urls[0]}" -Xq -c "CREATE TABLE IF NOT EXISTS probe (id INT PRIMARY KEY, via INT NOT NULL)"
stale=0
for ((k = 1; k <= n; k++)); do
    w=$((k % 3)) r=$(((k + 1) % 3))
    psql "${urls[w]}" -Xq -c "INSERT INTO probe VALUES ($k, $w)"
    c=$(psql "${urls[r]}" -XAt -c "SELECT count(*) FROM probe WHERE id = $k")
    [ "$c" = 1 ] || stale=$((stale + 1))
done
echo "writes=$n stale_reads=$stale"
for ((w = 0; w < 3; w++)); do
    echo "gateway ${urls[w]}:"
    psql "${urls[w]}" -X -c '\timing on' -c "UPSERT INTO probe VALUES (0, $w)" -c "UPSERT INTO probe VALUES (0, $w)" \
        -c "UPSERT INTO probe VALUES (0, $w)" | grep Time
done
