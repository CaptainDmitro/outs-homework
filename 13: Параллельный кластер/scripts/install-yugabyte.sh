#!/bin/bash
# Установка YugabyteDB на ноду (Ubuntu 24.04, x86_64)
set -xe
YB_VER=2025.2.7.0
YB_BUILD=b107
sudo apt-get -qq update
sudo apt-get -qq install -y python3 chrony >/dev/null
cat <<'L' | sudo tee /etc/security/limits.d/yugabyte.conf
yb  soft  nofile  1048576
yb  hard  nofile  1048576
yb  soft  nproc   12000
yb  hard  nproc   12000
L
curl -sSL -o /tmp/yb.tar.gz https://software.yugabyte.com/releases/$YB_VER/yugabyte-$YB_VER-$YB_BUILD-linux-x86_64.tar.gz
sudo mkdir -p /opt/yugabyte && sudo chown yb:yb /opt/yugabyte
tar xzf /tmp/yb.tar.gz -C /opt/yugabyte --strip-components=1
rm /tmp/yb.tar.gz
/opt/yugabyte/bin/post_install.sh
/opt/yugabyte/bin/yugabyted version
df -h /
