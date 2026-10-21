#!/bin/bash
# Загрузка trips порциями: [FIRST=id] ./load.sh LAST CHUNK URL [URL ...]
# Порции раздаются по кругу параллельным воркерам, по одному на каждый URL (узел).
rows=$1 chunk=$2 first=${FIRST:-1}
shift 2
urls=("$@")
n=${#urls[@]}
dir=$(dirname "$0")

worker() {
    local w=$1 lo hi try ok
    for ((lo = first + w * chunk; lo <= rows; lo += n * chunk)); do
        hi=$((lo + chunk - 1))
        ((hi > rows)) && hi=$rows
        ok=0
        for try in 1 2 3 4 5; do
            psql "${urls[w]}" -X -q -v ON_ERROR_STOP=1 -v lo=$lo -v hi=$hi -f "$dir/sql/load-chunk.sql" && { ok=1; break; }
            echo "worker $w: chunk $lo..$hi failed, retry $try" >&2
            sleep 5
        done
        ((ok)) || return 1
    done
}

start=$(date +%s)
pids=()
for ((w = 0; w < n; w++)); do
    worker $w &
    pids+=($!)
done
rc=0
for p in "${pids[@]}"; do wait $p || rc=1; done
echo "loaded ids $first..$rows in $(($(date +%s) - start)) s, rc=$rc"
exit $rc
