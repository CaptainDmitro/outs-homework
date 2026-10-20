set -x
head -2 /etc/os-release
uname -r
lscpu | grep -E '^(CPU\(s\)|Model name|Thread|Core|Socket|L3)'
free -h
lsblk -d -o NAME,SIZE,ROTA,TYPE
df -h /
# диск: последовательная запись и чтение блоками 1 МБ, случайное чтение блоками 8 КБ
fio --name=seqwrite --filename=/data/fio.test --rw=write --bs=1M --size=8G --direct=1 --ioengine=libaio --iodepth=32 | grep -E 'IOPS=|lat \(msec\).*avg'
fio --name=seqread --filename=/data/fio.test --rw=read --bs=1M --size=8G --direct=1 --ioengine=libaio --iodepth=32 | grep -E 'IOPS='
fio --name=randread --filename=/data/fio.test --rw=randread --bs=8k --size=8G --direct=1 --ioengine=libaio --iodepth=64 --numjobs=4 --runtime=30 --time_based --group_reporting | grep -E 'IOPS='
rm /data/fio.test
