#!/usr/bin/env bash
set -euo pipefail
HCFG="hermes --config /home/hermes/.hermes/config.toml"
H="docker exec hermes $HCFG"
RLY_NEUTRON="alley afraid soup fall idea toss can goose become valve initial strong forward bright dish figure check leopard decide warfare hub unusual join cart"

DATA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/data"

# Restore neutron relayer key
printf '%s' "$RLY_NEUTRON" > /tmp/rly_neutron.txt
docker cp /tmp/rly_neutron.txt hermes:/data/rly_neutron.txt
$H keys add --chain test-1 --mnemonic-file /data/rly_neutron.txt --key-name relayer --overwrite

# Restore wasmd relayer key (deterministic mnemonic written by init-wasmd.sh)
docker exec wasmd-chain cat /root/.wasmd/relayer.mnemonic > /tmp/rly_wasmd.txt
docker cp /tmp/rly_wasmd.txt hermes:/data/rly_wasmd.txt
$H keys add --chain wasmd-test --mnemonic-file /data/rly_wasmd.txt --key-name relayer --overwrite

# Check for existing open transfer channel via chain CLI (hermes query channels lacks -o json)
WASMD_CHANNEL=$(docker exec wasmd-chain wasmd q ibc channel channels --home /root/.wasmd -o json 2>/dev/null \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
ch=[c for c in d.get('channels',[]) if c.get('state')=='STATE_OPEN' and c.get('port_id','')=='transfer']
print(ch[0]['channel_id'] if ch else '')
" || true)

if [ -n "$WASMD_CHANNEL" ]; then
  echo "open transfer channel already exists on wasmd-test: $WASMD_CHANNEL (skipping create)"
  NEUTRON_CHANNEL=$(docker exec neutron-chain neutrond q ibc channel channels --home /opt/neutron/data/test-1 -o json 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
ch=[c for c in d.get('channels',[]) if c.get('state')=='STATE_OPEN' and c.get('port_id','')=='transfer']
print(ch[0]['channel_id'] if ch else '')
" || true)
else
  echo "creating client/connection/channel"
  $H create channel \
    --a-chain wasmd-test --b-chain test-1 \
    --a-port transfer --b-port transfer \
    --new-client-connection --yes 2>&1

  # Resolve ids from chain CLI JSON (robust; hermes query channels lacks -o json)
  WASMD_CHANNEL=$(docker exec wasmd-chain wasmd q ibc channel channels --home /root/.wasmd -o json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); ch=[c['channel_id'] for c in d.get('channels',[]) if c.get('state')=='STATE_OPEN' and c.get('port_id','')=='transfer']; print(ch[0] if ch else '')" || true)
  NEUTRON_CHANNEL=$(docker exec neutron-chain neutrond q ibc channel channels --home /opt/neutron/data/test-1 -o json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); ch=[c['channel_id'] for c in d.get('channels',[]) if c.get('state')=='STATE_OPEN' and c.get('port_id','')=='transfer']; print(ch[0] if ch else '')" || true)
fi

echo "WASMD_CHANNEL=$WASMD_CHANNEL"
echo "NEUTRON_CHANNEL=$NEUTRON_CHANNEL"

# Write ibc.env; fall back to writing via the hermes container if data/ is root-owned
mkdir -p "$DATA_DIR" 2>/dev/null || true
if printf 'WASMD_CHANNEL=%s\nNEUTRON_CHANNEL=%s\n' "$WASMD_CHANNEL" "$NEUTRON_CHANNEL" > "$DATA_DIR/ibc.env" 2>/dev/null; then
  : # direct write succeeded
else
  docker exec hermes sh -c "printf 'WASMD_CHANNEL=%s\nNEUTRON_CHANNEL=%s\n' '$WASMD_CHANNEL' '$NEUTRON_CHANNEL' > /data/ibc.env"
fi
echo "written to $DATA_DIR/ibc.env"
cat "$DATA_DIR/ibc.env"

echo "starting hermes relayer"
if docker exec hermes pgrep -x hermes >/dev/null; then
  echo "hermes already running"
else
  docker exec -d hermes $HCFG start
  sleep 3
fi
docker exec hermes pgrep hermes && echo "hermes relayer is running"
