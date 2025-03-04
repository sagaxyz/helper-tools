#!/bin/bash

set -e pipefail

# Channel numbers
SSC_TO_HUB_CHANNEL="${SSC_TO_HUB_CHANNEL:-channel-36}"

# mnemonic must be set
if [ -z "$MNEMONIC" ]; then
  echo "MNEMONIC is not set"
  exit 1
fi

# sscd and sagaosd binaries must be installed
if ! command -v sscd &> /dev/null; then
  echo "sscd not found"
  exit 1
fi
if ! command -v sagaosd &> /dev/null; then
  echo "sagaosd not found"
  exit 1
fi

# import key
if ! sscd keys add sscdkey --recover <<< "$MNEMONIC"; then
  echo "Failed to import key"
  exit 1
fi

# get the imported key address
SSC_ADDRESS=$(sscd keys show sscdkey -a)

# send IBC transaction every 30 seconds
while true; do
  sscd tx ibc-transfer transfer transfer $SSC_TO_HUB_CHANNEL $SSC_ADDRESS 10000usaga --from sscdkey --chain-id ssc-1 --fees 1500usaga --node https://ssc-rpc.sagarpc.io:443 -y
  sleep 30
  # check if the transaction is successful - uncomment when ready
  # sagaosd q bank balances $SSC_ADDRESS --node https://hub-5464111-1-cosmosrpc.jsonrpc.sagarpc.io:443 | jq '.balances[0].amount' | grep -q 1
done