#!/bin/bash

set pipefail

# Chain details
CHAIN_A_TO_B_CHANNEL="${CHAIN_A_TO_B_CHANNEL:-channel-36}"
CHAIN_B_TO_A_CHANNEL="${CHAIN_B_TO_A_CHANNEL:-channel-0}"
CHAIN_A_ID="${CHAIN_A_ID:-ssc-1}"
CHAIN_B_ID="${CHAIN_B_ID:-hub-5464111-1}"
CHAIN_A_ENDPOINT="${CHAIN_A_ENDPOINT:-https://ssc-rpc.sagarpc.io:443}"
CHAIN_B_ENDPOINT="${CHAIN_B_ENDPOINT:-https://hub-5464111-1-cosmosrpc.jsonrpc.sagarpc.io:443}"
CHAIN_A_DENOM="${CHAIN_A_DENOM:-usaga}"
CHAIN_A_IBC_DENOM="${CHAIN_A_IBC_DENOM:-ibc/572DE11CD97E8AE475A6D7F4DF05AEC459E68873018B8D5D9667F88C8E599E1E}"
CHAIN_B_DENOM="${CHAIN_B_DENOM:-lilc}"
CHAIN_B_IBC_DENOM="${CHAIN_B_IBC_DENOM:-ibc/FBDE0DA1907EC8B475C5DBC3FD8F794AE13919343B96D5DAF7245A2BC6196EA5}"
CHAIN_A_FEE_AMOUNT="${CHAIN_A_FEE_AMOUNT:-1500}"
CHAIN_B_FEE_AMOUNT="${CHAIN_B_FEE_AMOUNT:-20}"
CHAIN_A_BINARY="${CHAIN_A_BINARY:-sscd}"
CHAIN_B_BINARY="${CHAIN_B_BINARY:-sagaosd}"

TX_DELAY="${TX_DELAY:-180}"

# Keystore password must be set
if [ -z "$KEYPASSWD" ]; then
  echo "KEYPASSWD is not set"
  exit 1
fi

# Chain A mnemonic must be set
if [ -z "$CHAIN_A_MNEMONIC" ]; then
  echo "CHAIN_A_MNEMONIC is not set"
  exit 1
fi

# Chain B mnemonic must be set
if [ -z "$CHAIN_B_MNEMONIC" ]; then
  echo "CHAIN_B_MNEMONIC is not set"
  exit 1
fi

if ! (
  echo "$CHAIN_A_MNEMONIC"
  sleep 1
  echo $KEYPASSWD
  sleep 1
  echo $KEYPASSWD
) | $CHAIN_A_BINARY keys add chainakey --recover; then
  echo "Failed to import Chain A key"
  exit 1
fi
if ! (
  echo "$CHAIN_B_MNEMONIC"
  sleep 1
  echo $KEYPASSWD
  sleep 1
  echo $KEYPASSWD
) | $CHAIN_B_BINARY keys add chainbkey --recover; then
  echo "Failed to import Chain B key"
  exit 1
fi

# get the imported key addresses
CHAIN_A_ADDRESS=$(echo "$KEYPASSWD" | $CHAIN_A_BINARY keys show chainakey -a)
CHAIN_B_ADDRESS=$(echo "$KEYPASSWD" | $CHAIN_B_BINARY keys show chainbkey -a)

if [ -z "$CHAIN_A_ADDRESS" ]; then
  echo "Failed to get Chain A address"
  exit 1
fi
if [ -z "$CHAIN_B_ADDRESS" ]; then
  echo "Failed to get Chain B address"
  exit 1
fi

# Chain binaries must be installed
if ! command -v $CHAIN_A_BINARY &>/dev/null; then
  echo "$CHAIN_A_BINARY not found"
  exit 1
fi
if ! command -v $CHAIN_B_BINARY &>/dev/null; then
  echo "$CHAIN_B_BINARY not found"
  exit 1
fi

PORT=8080
METRICS_FILE="/tmp/metrics.log"

# Initialize the metrics file
echo "ibc_transfer_exporter{src_chain=\"$CHAIN_A_ID\", dst_chain=\"$CHAIN_B_ID\", status=\"success\"} 0" >"$METRICS_FILE"
# shellcheck disable=SC2129
echo "ibc_transfer_exporter{src_chain=\"$CHAIN_A_ID\", dst_chain=\"$CHAIN_B_ID\", status=\"failure\"} 0" >>"$METRICS_FILE"
echo "ibc_transfer_exporter{src_chain=\"$CHAIN_B_ID\", dst_chain=\"$CHAIN_A_ID\", status=\"success\"} 0" >>"$METRICS_FILE"
echo "ibc_transfer_exporter{src_chain=\"$CHAIN_B_ID\", dst_chain=\"$CHAIN_A_ID\", status=\"failure\"} 0" >>"$METRICS_FILE"

# IBC send loop
do_transfers() {
  chain_a_success_counter=0
  chain_a_failure_counter=0
  chain_b_success_counter=0
  chain_b_failure_counter=0
  while true; do
    chain_b_balance=$($CHAIN_B_BINARY q bank balances $CHAIN_B_ADDRESS --node $CHAIN_B_ENDPOINT --output json | jq -r '.balances[] | select(.denom == '\"$CHAIN_B_IBC_DENOM\"') | .amount')
    # if chain b balance is not set, set it to 0
    if [ -z "$chain_b_balance" ]; then
      chain_b_balance=0
    fi
    echo "chain b balance: $chain_b_balance"
    echo "$KEYPASSWD" | $CHAIN_A_BINARY tx ibc-transfer transfer transfer $CHAIN_A_TO_B_CHANNEL $CHAIN_B_ADDRESS 1$CHAIN_A_DENOM --from chainakey --chain-id $CHAIN_A_ID --fees $CHAIN_A_FEE_AMOUNT$CHAIN_A_DENOM --node $CHAIN_A_ENDPOINT -y
    sleep $TX_DELAY
    updated_chain_b_balance=$($CHAIN_B_BINARY q bank balances $CHAIN_B_ADDRESS --node $CHAIN_B_ENDPOINT --output json | jq -r '.balances[] | select(.denom == '\"$CHAIN_B_IBC_DENOM\"') | .amount')
    if [ -z "$updated_chain_b_balance" ]; then
      updated_chain_b_balance=0
    fi
    echo "chain b balance after transfer: $updated_chain_b_balance"
    # updated balance should be equal to the previous balance + 1
    if [ "$updated_chain_b_balance" -ne $((chain_b_balance + 1)) ]; then
      chain_a_failure_counter=$((chain_a_failure_counter + 1))
    else
      chain_a_success_counter=$((chain_a_success_counter + 1))
    fi

    # repeat the same for the opposite direction
    chain_a_balance=$($CHAIN_A_BINARY q bank balances $CHAIN_A_ADDRESS --node $CHAIN_A_ENDPOINT --output json | jq -r '.balances[] | select(.denom == '\"$CHAIN_A_IBC_DENOM\"') | .amount')
    if [ -z "$chain_a_balance" ]; then
      chain_a_balance=0
    fi
    echo "chain a balance: $chain_a_balance"
    echo "$KEYPASSWD" | $CHAIN_B_BINARY tx ibc-transfer transfer transfer $CHAIN_B_TO_A_CHANNEL $CHAIN_A_ADDRESS 1$CHAIN_B_DENOM --from chainbkey --chain-id $CHAIN_B_ID --fees $CHAIN_B_FEE_AMOUNT$CHAIN_B_DENOM --node $CHAIN_B_ENDPOINT -y
    sleep $TX_DELAY
    updated_chain_a_balance=$($CHAIN_A_BINARY q bank balances $CHAIN_A_ADDRESS --node $CHAIN_A_ENDPOINT --output json | jq -r '.balances[] | select(.denom == '\"$CHAIN_A_IBC_DENOM\"') | .amount')
    if [ -z "$updated_chain_a_balance" ]; then
      updated_chain_a_balance=0
    fi
    echo "chain a balance after transfer: $updated_chain_a_balance"
    if [ "$updated_chain_a_balance" -ne $((chain_a_balance + 1)) ]; then
      chain_b_failure_counter=$((chain_b_failure_counter + 1))
    else
      chain_b_success_counter=$((chain_b_success_counter + 1))
    fi
    # Update the metrics file counters
    echo "ibc_transfer_exporter{src_chain=\"$CHAIN_A_ID\", dst_chain=\"$CHAIN_B_ID\", status=\"success\"} $chain_a_success_counter" >"$METRICS_FILE"
    # shellcheck disable=SC2129
    echo "ibc_transfer_exporter{src_chain=\"$CHAIN_A_ID\", dst_chain=\"$CHAIN_B_ID\", status=\"failure\"} $chain_a_failure_counter" >>"$METRICS_FILE"
    echo "ibc_transfer_exporter{src_chain=\"$CHAIN_B_ID\", dst_chain=\"$CHAIN_A_ID\", status=\"success\"} $chain_b_success_counter" >>"$METRICS_FILE"
    echo "ibc_transfer_exporter{src_chain=\"$CHAIN_B_ID\", dst_chain=\"$CHAIN_A_ID\", status=\"failure\"} $chain_b_failure_counter" >>"$METRICS_FILE"
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
