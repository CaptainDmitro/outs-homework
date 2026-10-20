set -x
# остальные таблицы: параллельный COPY в 8 сессий, имя таблицы берётся из имени файла
pgcopy() { t=$(basename "$1"); psql -qc "COPY ${t%%.*} FROM '$1' (DELIMITER '|')"; }
export -f pgcopy
time (printf '%s\n' $D/lineitem.tbl.* $D/partsupp.tbl.* $D/part.tbl.* $D/supplier.tbl $D/nation.tbl $D/region.tbl | xargs -P 8 -I{} bash -c 'pgcopy {}')

# первичные ключи, индексы для фильтров по датам, статистика и карта видимости
time psql -e -c '\timing on' -f /opt/bench/pg-indexes.sql
