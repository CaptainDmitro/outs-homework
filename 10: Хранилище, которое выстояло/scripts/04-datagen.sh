set -x
cd $D
# большие таблицы режутся на 8 частей и генерируются в 8 процессов; customer генерируется потоком при загрузке
time (
  for t in L O P S; do for i in $(seq 1 8); do echo $t $i; done; done |
    xargs -P 8 -n 2 sh -c '/opt/tpch-dbgen/dbgen -q -f -s '$SF' -T $0 -C 8 -S $1'
  for t in s n r; do /opt/tpch-dbgen/dbgen -q -f -s $SF -T $t; done
)
ls -l $D
head -2 lineitem.tbl.1
# dbgen ставит разделитель и после последнего поля
time (ls $D/*.tbl* | xargs -P 8 -n 1 sed -i 's/|$//')
head -2 lineitem.tbl.1
du -sh --apparent-size $D
for t in lineitem orders partsupp part supplier nation region; do echo "$t $(cat $D/$t.tbl* | wc -l)"; done
