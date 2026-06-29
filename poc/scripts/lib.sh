#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$HERE/../data/ibc.env" ]       && source "$HERE/../data/ibc.env"
[ -f "$HERE/../data/contracts.env" ] && source "$HERE/../data/contracts.env"

# keys show -a conflicts with --node/-o json; query commands reject --keyring-backend
wasmd_e(){   docker exec wasmd-chain wasmd     "$@" --home /root/.wasmd            --node tcp://localhost:26657 -o json; }
neutron_e(){ docker exec neutron-chain neutrond "$@" --home /opt/neutron/data/test-1 --node tcp://localhost:26657 -o json; }

ce(){    case $1 in wasmd) shift; wasmd_e "$@";; neutron) shift; neutron_e "$@";; *) echo "ce: unknown chain '$1'" >&2; return 1;; esac; }
cid(){   case $1 in wasmd) echo wasmd-test;; neutron) echo test-1;; esac; }
fee(){   case $1 in wasmd) echo 0.025stake;; neutron) echo 0.025untrn;; esac; }
denom(){ case $1 in wasmd) echo stake;; neutron) echo untrn;; esac; }
from(){  case $1 in wasmd) echo validator;; neutron) echo demowallet1;; esac; }

# keys show -a cannot use --node or -o json
addr(){
  case $1 in
    wasmd)   docker exec wasmd-chain   wasmd    keys show validator  --home /root/.wasmd            --keyring-backend test -a;;
    neutron) docker exec neutron-chain neutrond keys show demowallet1 --home /opt/neutron/data/test-1 --keyring-backend test -a;;
  esac | tr -d '\r'
}

channel(){ case $1 in wasmd) echo "${WASMD_CHANNEL:-channel-0}";; neutron) echo "${NEUTRON_CHANNEL:-channel-0}";; esac; }

# bcast: broadcast a tx, return txhash
bcast(){ local c=$1; shift
  ce "$c" tx "$@" \
    --from "$(from "$c")" --chain-id "$(cid "$c")" \
    --keyring-backend test \
    --gas auto --gas-adjustment 1.4 --gas-prices "$(fee "$c")" -y \
  | jq -r .txhash
}

# wait_tx: poll until tx lands, print JSON; return 1 on timeout
wait_tx(){ local c=$1 h=$2 out
  for _ in $(seq 1 30); do
    out=$(ce "$c" q tx "$h" 2>/dev/null) && { echo "$out"; return 0; }
    sleep 1
  done
  echo "wait_tx: timeout for $h" >&2; return 1
}

# q: smart query → .data JSON
q(){ local c=$1 contract=$2 msg=$3
  ce "$c" q wasm contract-state smart "$contract" "$msg" | jq .data
}

# bal: bank balance integer for a denom
bal(){ ce "$1" q bank balances "$2" | jq -r --arg d "$3" '[.balances[]|select(.denom==$d)|.amount]|if length>0 then .[0] else "0" end'; }

# transfer: native ICS-20 from the chain's default account, returns packet_sequence
transfer(){ local c=$1 amt=$2 dn=$3 recv=$4 memo=$5; local h
  h=$(bcast "$c" ibc-transfer transfer transfer "$(channel "$c")" "$recv" "${amt}${dn}" --memo "$memo")
  wait_tx "$c" "$h" | jq -r '.events[]|select(.type=="send_packet").attributes[]|select(.key=="packet_sequence").value'
}

# probe_send: make the probe the IBC packet sender via wasm execute transfer
# memo is always passed explicitly; omitting it triggers the probe's auto-default both-callbacks memo
probe_send(){ local c=$1 probe=$2 to_addr=$3 ch=$4 funds=$5 memo=$6 ts=${7:-}; local msg h
  # Use jq to safely encode the memo string (it may itself be JSON)
  if [ -n "$ts" ]; then
    msg=$(jq -n --arg to "$to_addr" --arg ch "$ch" --arg m "$memo" --argjson ts "$ts" \
      '{"transfer":{"to_address":$to,"channel_id":$ch,"memo":$m,"timeout_seconds":$ts}}')
  else
    msg=$(jq -n --arg to "$to_addr" --arg ch "$ch" --arg m "$memo" \
      '{"transfer":{"to_address":$to,"channel_id":$ch,"memo":$m}}')
  fi
  h=$(bcast "$c" wasm execute "$probe" "$msg" --amount "$funds")
  wait_tx "$c" "$h" | jq -r '.events[]|select(.type=="send_packet").attributes[]|select(.key=="packet_sequence").value'
}

derive_intermediate(){ python3 "$HERE/derive.py" "$1" "$2" "$3"; }
