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

wget https://golang.org/dl/go1.22.2.linux-amd64.tar.gz
tar -C /usr/local -xzf go1.22.2.linux-amd64.tar.gz
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
sudo -u sscdserviceuser git clone -b v0.1.5 https://github.com/sagaxyz/ssc /tmp/ssc
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
sudo -u sscdserviceuser tomlq -t '.p2p.seeds = "7a76f8c6d905325d6739711ed40399a501b1484b@34.107.32.74:26656,33d4f88adba9f2394a09f65401908a71352260fe@34.64.222.209:26656,084a2b4309d7ff273084671b9c9f6cffc6587131@34.174.56.202:26656"' /opt/sscd/.ssc/config/config.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/config.toml.out > /dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/config.toml.out /opt/sscd/.ssc/config/config.toml

# get genesis file
sudo -u sscdserviceuser wget -O /opt/sscd/.ssc/config/genesis.json 'https://raw.githubusercontent.com/sagaxyz/mainnet/main/genesis/genesis.json'

# adjust config.toml
sudo -u sscdserviceuser tomlq -t '.rpc.laddr = "tcp://0.0.0.0:80"' /opt/sscd/.ssc/config/config.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/config.toml.out > /dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/config.toml.out /opt/sscd/.ssc/config/config.toml
sudo -u sscdserviceuser tomlq -t '.rpc.cors_allowed_origins = ["*"]' /opt/sscd/.ssc/config/config.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/config.toml.out > /dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/config.toml.out /opt/sscd/.ssc/config/config.toml

# obtain state sync actual data
STATUS_URL=http://34.134.161.74
CURRENT_BLOCK=$(curl -s $STATUS_URL/status | jq '.result.sync_info.latest_block_height'| awk 'gsub("\"","",$0)')
TRUST_HEIGHT=$((CURRENT_BLOCK / 1000 * 1000 ))
TRUST_BLOCK=$(curl -s $STATUS_URL/block\?height=$TRUST_HEIGHT)
TRUST_HASH=$(echo $TRUST_BLOCK | jq -r '.result.block_id.hash')

# configure state sync
sudo -u sscdserviceuser tomlq -t '.statesync.enable = true' /opt/sscd/.ssc/config/config.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/config.toml.out > /dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/config.toml.out /opt/sscd/.ssc/config/config.toml
sudo -u sscdserviceuser tomlq -t '.statesync.trust_height = '$TRUST_HEIGHT'' /opt/sscd/.ssc/config/config.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/config.toml.out > /dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/config.toml.out /opt/sscd/.ssc/config/config.toml
sudo -u sscdserviceuser tomlq -t '.statesync.trust_hash = '\"$TRUST_HASH\"'' /opt/sscd/.ssc/config/config.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/config.toml.out > /dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/config.toml.out /opt/sscd/.ssc/config/config.toml
sudo -u sscdserviceuser tomlq -t '.statesync.rpc_servers = "tcp://34.107.32.74:26657,tcp://34.64.222.209:26657,tcp://34.174.56.202:26657"' /opt/sscd/.ssc/config/config.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/config.toml.out > /dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/config.toml.out /opt/sscd/.ssc/config/config.toml

# start
systemctl enable sscd.service
systemctl start sscd
