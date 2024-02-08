#!/bin/bash

set -e pipefail

# if service exists, do nothing
if systemctl list-units --full -all | grep -q 'sscd.service'; then
  echo "Service exists."
  exit 0
fi

# install dependencies
apt update
apt upgrade -y
apt install build-essential make wget git daemon jq python3-pip -y
pip install yq

GO_VERSION="${GO_VERSION:-1.22.2}"
SSC_VERSION="${SSC_VERSION:-v0.1.5}"

wget https://golang.org/dl/go$GO_VERSION.linux-amd64.tar.gz
tar -C /usr/local -xzf go$GO_VERSION.linux-amd64.tar.gz
# shellcheck disable=SC2016
# shellcheck disable=SC1091
echo 'export PATH=$PATH:/usr/local/go/bin' | tee -a /etc/profile
# shellcheck disable=SC2016
echo 'export GOPATH=$HOME/go' | tee -a /etc/profile
# shellcheck disable=SC1091
source /etc/profile
go version

# create a user for sscd
useradd -r -s /bin/false -d /opt/sscd sscdserviceuser
mkdir -p /opt/sscd
chown -R sscdserviceuser:sscdserviceuser /opt/sscd
mkdir -p /var/log/sscd
chown -R sscdserviceuser:sscdserviceuser /var/log/sscd

# install ssc
sudo -u sscdserviceuser git clone -b $SSC_VERSION https://github.com/sagaxyz/ssc /tmp/ssc
sudo -u sscdserviceuser PATH=$PATH:/usr/local/go/bin make install -C /tmp/ssc/
cp /opt/sscd/go/bin/sscd /usr/local/bin/
sudo -u sscdserviceuser sscd version

# create sscd service
sudo tee /etc/systemd/system/sscd.service <<EOF
[Unit]
Description=sscd daemon
After=network-online.target

[Service]
User=sscdserviceuser
Group=sscdserviceuser
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=sscd start --home /opt/sscd/.ssc/
StandardOutput=append:/var/log/sscd/sscd.log
StandardError=append:/var/log/sscd/sscd_error.log
Restart=always
RestartSec=3
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

# init ssc
sudo -u sscdserviceuser HOME=/opt/sscd/ sscd init saganode --chain-id ssc-1

# set seeds
sudo -u sscdserviceuser tomlq -t '.p2p.seeds = "98a9866c1a0728c117ea7ad579bed739dbb72b47@ssc-seed-eu.sagarpc.io:26656,a367315c6319d55a9d17dfa13a96c19500bc6a02@ssc-seed-us.sagarpc.io:26656,0c41e31ae643549107f57d4c9e29f7193f1a36e0@ssc-seed-kr.sagarpc.io:26656"' /opt/sscd/.ssc/config/config.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/config.toml.out >/dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/config.toml.out /opt/sscd/.ssc/config/config.toml

# get genesis file
sudo -u sscdserviceuser wget -O /opt/sscd/.ssc/config/genesis.json 'https://raw.githubusercontent.com/sagaxyz/mainnet/main/genesis/genesis.json'

# adjust config.toml
sudo -u sscdserviceuser tomlq -t '.rpc.laddr = "tcp://0.0.0.0:80"' /opt/sscd/.ssc/config/config.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/config.toml.out >/dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/config.toml.out /opt/sscd/.ssc/config/config.toml

# adjust app.toml
sudo -u sscdserviceuser tomlq -t '."state-sync"."snapshot-interval" = 1000' /opt/sscd/.ssc/config/app.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/app.toml.out >/dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/app.toml.out /opt/sscd/.ssc/config/app.toml

# obtain state sync actual data
RPC_URL=https://ssc-rpc.sagarpc.io
CURRENT_BLOCK=$(curl -s $RPC_URL/status | jq '.result.sync_info.latest_block_height' | awk 'gsub("\"","",$0)')
TRUST_HEIGHT=$((CURRENT_BLOCK - 1000))
TRUST_BLOCK=$(curl -s $RPC_URL/block\?height=$TRUST_HEIGHT)
TRUST_HASH=$(echo $TRUST_BLOCK | jq -r '.result.block_id.hash')

# configure state sync
sudo -u sscdserviceuser tomlq -t '.statesync.enable = true' /opt/sscd/.ssc/config/config.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/config.toml.out >/dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/config.toml.out /opt/sscd/.ssc/config/config.toml
sudo -u sscdserviceuser tomlq -t '.statesync.trust_height = '$TRUST_HEIGHT'' /opt/sscd/.ssc/config/config.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/config.toml.out >/dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/config.toml.out /opt/sscd/.ssc/config/config.toml
sudo -u sscdserviceuser tomlq -t '.statesync.trust_hash = '\"$TRUST_HASH\"'' /opt/sscd/.ssc/config/config.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/config.toml.out >/dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/config.toml.out /opt/sscd/.ssc/config/config.toml
sudo -u sscdserviceuser tomlq -t '.statesync.rpc_servers = "tcp://ssc-statesync-eu.sagarpc.io:80,tcp://ssc-statesync-us.sagarpc.io:80,tcp://ssc-statesync-kr.sagarpc.io:80"' /opt/sscd/.ssc/config/config.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/config.toml.out >/dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/config.toml.out /opt/sscd/.ssc/config/config.toml
sudo -u sscdserviceuser tomlq -t '.statesync.discovery_time = "30s"' /opt/sscd/.ssc/config/config.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/config.toml.out >/dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/config.toml.out /opt/sscd/.ssc/config/config.toml
sudo -u sscdserviceuser tomlq -t '.statesync.chunk_request_timeout = "60s"' /opt/sscd/.ssc/config/config.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/config.toml.out >/dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/config.toml.out /opt/sscd/.ssc/config/config.toml

# start
systemctl enable sscd.service
systemctl start sscd
