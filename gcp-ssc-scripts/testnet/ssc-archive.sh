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
sudo -u sscdserviceuser HOME=/opt/sscd/ sscd init saganode --chain-id ssc-testnet-2

# set seeds
sudo -u sscdserviceuser tomlq -t '.p2p.seeds = "0cec3c2ba9e3f5d01db08a48efa0b37daab10c88@testnet2-seed-eu.sagarpc.io:26656,1b18cc75bc5933c24c338b1c9979ea8fad967850@testnet2-seed-us.sagarpc.io:26656,51319e6a39735c95a85228684946e68b4f95c87a@testnet2-seed-kr.sagarpc.io:26656"' /opt/sscd/.ssc/config/config.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/config.toml.out >/dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/config.toml.out /opt/sscd/.ssc/config/config.toml

# get genesis file
sudo -u sscdserviceuser wget -O /opt/sscd/.ssc/config/genesis.json 'https://raw.githubusercontent.com/sagaxyz/testnet-2/main/genesis/genesis.json'

# adjust config.toml
sudo -u sscdserviceuser tomlq -t '.rpc.laddr = "tcp://0.0.0.0:26657"' /opt/sscd/.ssc/config/config.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/config.toml.out >/dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/config.toml.out /opt/sscd/.ssc/config/config.toml

# adjust app.toml
sudo -u sscdserviceuser tomlq -t '.pruning = "nothing"' /opt/sscd/.ssc/config/app.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/app.toml.out >/dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/app.toml.out /opt/sscd/.ssc/config/app.toml

# for archival node we need to get a snapshot
sudo -u sscdserviceuser wget -O /opt/sscd/latest.tar https://saga-snapshots-testnet.s3.amazonaws.com/ssc/archive/latest.tar
sudo -u sscdserviceuser tar -xvf /opt/sscd/latest.tar -C /opt/sscd/.ssc/
sudo -u sscdserviceuser mv /opt/sscd/.ssc/root/.ssc/data/* /opt/sscd/.ssc/data/
sudo -u sscdserviceuser rm -f /opt/sscd/latest.tar

# start
systemctl enable sscd.service
systemctl start sscd
