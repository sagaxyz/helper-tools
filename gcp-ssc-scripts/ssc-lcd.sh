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

# set persistent peers
sudo -u sscdserviceuser sed -i 's/persistent_peers = ""/persistent_peers = "fe0a7c342c3ea6934b89f87a4e5d93ae02792243@195.14.6.50:26014,7b205854267901c355fc1a18908764c118431375@51.81.167.206:17300,054b42595365063100789a218070023bb749c156@66.172.36.135:11156,8abc9ea7ab1db58c26eae9b55344644893f64d49@66.172.36.136:11156,4318a1fafa158df21b98d28bf5ed529f79db57c7@95.216.38.96:11156"/g' /opt/sscd/.ssc/config/config.toml

# get genesis file
sudo -u sscdserviceuser wget -O /opt/sscd/.ssc/config/genesis.json 'https://raw.githubusercontent.com/sagaxyz/mainnet/main/genesis/genesis.json'

# adjust app.toml
sudo -u sscdserviceuser tomlq -t '.api.enable = true' /opt/sscd/.ssc/config/app.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/app.toml.out > /dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/app.toml.out /opt/sscd/.ssc/config/app.toml
sudo -u sscdserviceuser tomlq -t '.api.address = "tcp://0.0.0.0:80"' /opt/sscd/.ssc/config/app.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/app.toml.out > /dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/app.toml.out /opt/sscd/.ssc/config/app.toml
sudo -u sscdserviceuser tomlq -t '.api."enabled-unsafe-cors" = true' /opt/sscd/.ssc/config/app.toml | sudo -u sscdserviceuser tee /opt/sscd/.ssc/config/app.toml.out > /dev/null && sudo -u sscdserviceuser mv /opt/sscd/.ssc/config/app.toml.out /opt/sscd/.ssc/config/app.toml

# start
systemctl enable sscd.service
systemctl start sscd