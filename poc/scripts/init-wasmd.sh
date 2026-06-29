#!/usr/bin/env bash
set -euo pipefail
HOME_DIR=/root/.wasmd
CHAIN_ID=wasmd-test
[ -f "$HOME_DIR/config/genesis.json" ] && exit 0

wasmd init val --chain-id "$CHAIN_ID" --home "$HOME_DIR"
wasmd keys add validator --home "$HOME_DIR" --keyring-backend test
# Generate relayer key; capture mnemonic from JSON output so hermes can recover it later
wasmd keys add relayer --home "$HOME_DIR" --keyring-backend test --output json \
  | python3 -c "import sys,json; d=json.load(sys.stdin); open('$HOME_DIR/relayer.mnemonic','w').write(d['mnemonic'])"
val=$(wasmd keys show validator -a --home "$HOME_DIR" --keyring-backend test)
rly=$(wasmd keys show relayer  -a --home "$HOME_DIR" --keyring-backend test)
wasmd genesis add-genesis-account "$val" 100000000000stake --home "$HOME_DIR"
wasmd genesis add-genesis-account "$rly" 100000000000stake --home "$HOME_DIR"
wasmd genesis gentx validator 1000000000stake --chain-id "$CHAIN_ID" --home "$HOME_DIR" --keyring-backend test
wasmd genesis collect-gentxs --home "$HOME_DIR"

cfg=$HOME_DIR/config/config.toml; app=$HOME_DIR/config/app.toml
sed -i 's/timeout_commit = "5s"/timeout_commit = "1s"/' "$cfg"
sed -i 's#laddr = "tcp://127.0.0.1:26657"#laddr = "tcp://0.0.0.0:26657"#' "$cfg"
sed -i '/^\[api\]/,/^\[/{s/^enable = false/enable = true/}' "$app"
sed -i 's/^minimum-gas-prices = ""/minimum-gas-prices = "0.025stake"/' "$app"
sed -i 's#address = "tcp://localhost:1317"#address = "tcp://0.0.0.0:1317"#' "$app"
sed -i 's#address = "localhost:9090"#address = "0.0.0.0:9090"#' "$app"

python3 - "$HOME_DIR/config/genesis.json" <<'PY'
import json,sys
p=sys.argv[1]; g=json.load(open(p))
w=g["app_state"].setdefault("wasm",{}).setdefault("params",{})
w["code_upload_access"]={"permission":"Everybody","addresses":[]}
w["instantiate_default_permission"]="Everybody"
with open(p,"w") as f: json.dump(g,f,indent=2)
PY
