#!/usr/bin/env bash
set -euo pipefail
cd /opt/neutron
export CHAINID=test-1 STAKEDENOM=untrn
export RPCPORT=26657 RESTPORT=1317 P2PPORT=26656
GEN=./data/test-1/config/genesis.json
if [ ! -f "$GEN" ]; then
  bash network/init.sh
  bash network/init-neutrond.sh
  python3 - "$GEN" <<'PY'
import json,sys
p=sys.argv[1]; g=json.load(open(p))
w=g["app_state"].setdefault("wasm",{}).setdefault("params",{})
w["code_upload_access"]={"permission":"Everybody","addresses":[]}
w["instantiate_default_permission"]="Everybody"
# Disable feerefunder so contract senders can do IBC transfers without pre-paying relayer fees.
# This is safe in a test harness where we run our own relayer.
fr=g["app_state"].setdefault("feerefunder",{}).setdefault("params",{})
fr["fee_enabled"]=False
fr["min_fee"]={"recv_fee":[],"ack_fee":[],"timeout_fee":[]}
json.dump(g,open(p,"w"),indent=2)
PY
fi
RUN_BACKGROUND=0 bash network/start.sh
