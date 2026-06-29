#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CBPLUS="$HERE/.."
source "$HERE/lib.sh"

store(){ # store <chain> <wasm_path> → code_id
  local c=$1 f=$2 base; base=$(basename "$f")
  docker cp "$f" "${c}-chain:/tmp/$base"
  local h; h=$(bcast "$c" wasm store "/tmp/$base")
  wait_tx "$c" "$h" \
    | jq -r '.events[]|select(.type=="store_code").attributes[]|select(.key=="code_id").value'
}

inst(){ # inst <chain> <code_id> <label> → contract_address
  local c=$1 id=$2 label=$3 h
  h=$(bcast "$c" wasm instantiate "$id" '{}' --label "$label" --no-admin)
  wait_tx "$c" "$h" \
    | jq -r '.events[]|select(.type=="instantiate").attributes[]|select(.key=="_contract_address").value'
}

perm=$(neutron_e q wasm params | jq -r '.code_upload_access.permission')
echo "neutron code_upload_access.permission: $perm"
[ "$perm" = "Everybody" ] || { echo "ERROR: neutron wasm upload restricted ($perm)" >&2; exit 1; }

{
  for c in wasmd neutron; do
    pid=$(store "$c" "$CBPLUS/contracts/probe/artifacts/probe.wasm")
    echo "${c^^}_PROBE=$(inst "$c" "$pid" probe)"
  done
} | tee /tmp/_contracts.env

# Write contracts.env; fall back to writing via hermes container if data/ is root-owned
if ! cp /tmp/_contracts.env "$CBPLUS/data/contracts.env" 2>/dev/null; then
  docker exec -i hermes sh -c "cat > /data/contracts.env" < /tmp/_contracts.env
fi

cat "$CBPLUS/data/contracts.env"
