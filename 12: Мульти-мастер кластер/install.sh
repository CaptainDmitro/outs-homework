#!/bin/bash
# Установка CockroachDB на ВМ с Mac: ./install.sh TGZ IP [IP ...]
# Архив скачивается на Mac и сверяется с .sha256sum заранее.
set -ex
tgz=$1
shift
name=$(basename "$tgz" .tgz)
for ip in "$@"; do
    scp -q "$tgz" ubuntu@$ip:/tmp/
    ssh ubuntu@$ip "tar -xzf /tmp/$name.tgz -C /tmp && sudo cp /tmp/$name/cockroach /usr/local/bin/ \
        && for f in /etc/cockroach/*.env; do sudo systemctl enable --now cockroach@\$(basename \$f .env); done \
        && cockroach version | head -2 && systemctl list-units 'cockroach@*' --no-pager --no-legend" </dev/null
done
