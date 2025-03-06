#!/bin/bash

set -e pipefail

# Chain details
SSC_TO_HUB_CHANNEL="${SSC_TO_HUB_CHANNEL:-channel-36}"
HUB_TO_SSC_CHANNEL="${HUB_TO_SSC_CHANNEL:-channel-0}"
SSC_CHAIN_ID="${SSC_CHAIN_ID:-ssc-1}"
HUB_CHAIN_ID="${HUB_CHAIN_ID:-hub-5464111-1}"
SSC_ENDPOINT="${SSC_ENDPOINT:-https://ssc-rpc.sagarpc.io:443}"
HUB_ENDPOINT="${HUB_ENDPOINT:-https://hub-5464111-1-cosmosrpc.jsonrpc.sagarpc.io:443}"
SSC_DENOM="${SSC_DENOM:-usaga}"
HUB_IBC_DENOM="${HUB_IBC_DENOM:-ibc/FBDE0DA1907EC8B475C5DBC3FD8F794AE13919343B96D5DAF7245A2BC6196EA5}"
HUB_NATIVE_DENOM="${HUB_NATIVE_DENOM:-lilc}"

TX_DELAY="${TX_DELAY:-180}"

# SSC mnemonic must be set
if [ -z "$SSC_MNEMONIC" ]; then
  echo "SSC_MNEMONIC is not set"
  exit 1
fi

# hub mnemonic must be set
if [ -z "$HUB_MNEMONIC" ]; then
  echo "HUB_MNEMONIC is not set"
  exit 1
fi

# import keys
# if keys are already imported, just continue
if ! sscd keys show sscdkey -a; then
  if ! sscd keys add sscdkey --recover <<<"$SSC_MNEMONIC"; then
    echo "Failed to import SSC key"
    exit 1
  fi
fi
if ! sagaosd keys show hubkey -a; then
  if ! sagaosd keys add hubkey --recover <<<"$HUB_MNEMONIC"; then
    echo "Failed to import hub key"
    exit 1
  fi
fi

# get the imported key addresses
SSC_ADDRESS=$(sscd keys show sscdkey -a)
HUB_ADDRESS=$(sagaosd keys show hubkey -a)

# sscd and sagaosd binaries must be installed
if ! command -v sscd &>/dev/null; then
  echo "sscd not found"
  exit 1
fi
if ! command -v sagaosd &>/dev/null; then
  echo "sagaosd not found"
  exit 1
fi

PORT=8080
METRICS_FILE="/tmp/metrics.log"

# Initialize the metrics file
echo "ibc_transfer_exporter{scr_chain=\"$SSC_CHAIN_ID\", dst_chain=\"$HUB_CHAIN_ID\", status=\"success\"} 0" >"$METRICS_FILE"
# shellcheck disable=SC2129
echo "ibc_transfer_exporter{scr_chain=\"$SSC_CHAIN_ID\", dst_chain=\"$HUB_CHAIN_ID\", status=\"failure\"} 0" >>"$METRICS_FILE"
echo "ibc_transfer_exporter{scr_chain=\"$HUB_CHAIN_ID\", dst_chain=\"$SSC_CHAIN_ID\", status=\"success\"} 0" >>"$METRICS_FILE"
echo "ibc_transfer_exporter{scr_chain=\"$HUB_CHAIN_ID\", dst_chain=\"$SSC_CHAIN_ID\", status=\"failure\"} 0" >>"$METRICS_FILE"

# IBC send loop
do_transfers() {
  ssc_success_counter=0
  ssc_failure_counter=0
  hub_success_counter=0
  hub_failure_counter=0
  while true; do
    hub_balance=$(sagaosd q bank balances $HUB_ADDRESS --node $HUB_ENDPOINT --output json | jq -r '.balances[] | select(.denom == '\"$HUB_IBC_DENOM\"') | .amount')
    # if hub balance is not set, set it to 0
    if [ -z "$hub_balance" ]; then
      hub_balance=0
    fi
    echo "hub balance: $hub_balance"
    sscd tx ibc-transfer transfer transfer $SSC_TO_HUB_CHANNEL $HUB_ADDRESS 1$SSC_DENOM --from sscdkey --chain-id $SSC_CHAIN_ID --fees 1500$SSC_DENOM --node $SSC_ENDPOINT -y
    sleep $TX_DELAY
    updated_hub_balance=$(sagaosd q bank balances $HUB_ADDRESS --node $HUB_ENDPOINT --output json | jq -r '.balances[] | select(.denom == '\"$HUB_IBC_DENOM\"') | .amount')
    if [ -z "$updated_hub_balance" ]; then
      updated_hub_balance=0
    fi
    echo "hub balance after transfer: $updated_hub_balance"
    # updated balance should be equal to the previous balance + 1
    if [ "$updated_hub_balance" -ne $((hub_balance + 1)) ]; then
      ssc_failure_counter=$((ssc_failure_counter + 1))
    else
      ssc_success_counter=$((ssc_success_counter + 1))
    fi

    # repeat the same for the opposite direction
    ssc_balance=$(sscd q bank balances $SSC_ADDRESS --node $SSC_ENDPOINT --output json | jq -r '.balances[] | select(.denom == '\"$SSC_DENOM\"') | .amount')
    if [ -z "$ssc_balance" ]; then
      ssc_balance=0
    fi
    echo "ssc balance: $ssc_balance"
    sagaosd tx ibc-transfer transfer transfer $HUB_TO_SSC_CHANNEL $SSC_ADDRESS 1$HUB_IBC_DENOM --from hubkey --chain-id $HUB_CHAIN_ID --fees 20$HUB_NATIVE_DENOM --node $HUB_ENDPOINT -y
    sleep $TX_DELAY
    updated_ssc_balance=$(sscd q bank balances $SSC_ADDRESS --node $SSC_ENDPOINT --output json | jq -r '.balances[] | select(.denom == '\"$SSC_DENOM\"') | .amount')
    if [ -z "$updated_ssc_balance" ]; then
      updated_ssc_balance=0
    fi
    echo "ssc balance after transfer: $updated_ssc_balance"
    if [ "$updated_ssc_balance" -ne $((ssc_balance + 1)) ]; then
      hub_failure_counter=$((hub_failure_counter + 1))
    else
      hub_success_counter=$((hub_success_counter + 1))
    fi
    # Update the metrics file counters
    echo "ibc_transfer_exporter{scr_chain=\"$SSC_CHAIN_ID\", dst_chain=\"$HUB_CHAIN_ID\", status=\"success\"} $ssc_success_counter" >"$METRICS_FILE"
    # shellcheck disable=SC2129
    echo "ibc_transfer_exporter{scr_chain=\"$SSC_CHAIN_ID\", dst_chain=\"$HUB_CHAIN_ID\", status=\"failure\"} $ssc_failure_counter" >>"$METRICS_FILE"
    echo "ibc_transfer_exporter{scr_chain=\"$HUB_CHAIN_ID\", dst_chain=\"$SSC_CHAIN_ID\", status=\"success\"} $hub_success_counter" >>"$METRICS_FILE"
    echo "ibc_transfer_exporter{scr_chain=\"$HUB_CHAIN_ID\", dst_chain=\"$SSC_CHAIN_ID\", status=\"failure\"} $hub_failure_counter" >>"$METRICS_FILE"
  done
}

function calc_content_length() {
  # shellcheck disable=SC2000
  printf "%s" "$(echo "$1" | wc -c)"
}

# Generate an HTTP 200 OK response with the given body.
function gen_response() {
  local body="$1"
  echo "HTTP/1.1 200 OK"
  echo "Connection: close"
  echo "Content-Type: text/plain; charset=UTF-8"
  echo "Content-Length: $(calc_content_length "$body")"
  echo
  echo "$body"
}

# Generate an HTTP 404 Not Found response.
function gen_404_response() {
  local body="Not Found"
  echo "HTTP/1.1 404 Not Found"
  echo "Connection: close"
  echo "Content-Type: text/plain; charset=UTF-8"
  echo "Content-Length: $(calc_content_length "$body")"
  echo
  echo "$body"
}

function handleRequest() {
  # Check if the request is for /metrics.
  read -r request_line
  if [[ "$request_line" =~ ^GET\ /metrics\  ]]; then
    body=$(cat "$METRICS_FILE")
    gen_response "$body" >response
  else
    gen_404_response >response
  fi
}

do_transfers &

rm -f response
mkfifo response

echo "Listening on port $PORT..."
while true; do
  # shellcheck disable=SC2002
  cat response | nc -l $PORT | handleRequest
done
