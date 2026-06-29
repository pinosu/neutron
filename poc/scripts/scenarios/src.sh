#!/usr/bin/env bash
# scenarios/src.sh – source-side IBC scenarios 10-15

poll_stat_gt(){
  local c=$1 p=$2 field=$3 floor=$4 timeout=${5:-60} elapsed=0 n
  while [ "$elapsed" -lt "$timeout" ]; do
    n=$(stat "$c" "$p" "$field")
    [ "$n" -gt "$floor" ] && return 0
    sleep 2; elapsed=$((elapsed+2))
  done
  return 1
}

s10(){
  local a0 a1 seq memo
  a0=$(stat wasmd "$WASMD_PROBE" ack)
  memo=$(jq -nc --arg a "$WASMD_PROBE" '{src_callback:{address:$a}}')
  seq=$(probe_send wasmd "$WASMD_PROBE" "$(addr neutron)" "$(channel wasmd)" "100stake" "$memo")
  [ -n "$seq" ] || { echo "FAIL s10: probe_send returned empty sequence"; return 1; }
  poll_stat_gt wasmd "$WASMD_PROBE" ack "$a0" 60 \
    || { echo "FAIL s10: timeout waiting for src_callback ack on wasmd (seq=$seq)"; return 1; }
  a1=$(stat wasmd "$WASMD_PROBE" ack)
  [ "$a1" -eq $((a0+1)) ] || { echo "FAIL s10: ack $a0->$a1 (expected $((a0+1)))"; return 1; }
  echo "PASS s10 (ack $a0->$a1, seq=$seq)"
}

# Requires feerefunder.fee_enabled=false in neutron genesis (contracts need fees otherwise).
# Note: on neutron the same ack ALSO bumps lifecycle via x/transfer module sudo
# (neutron fires sudo({"response":...}) on any contract sender regardless of memo).
# s11 isolates its assertion to ack only; s13 covers the lifecycle bump separately.
s11(){
  local a0 a1 seq memo
  a0=$(stat neutron "$NEUTRON_PROBE" ack)
  memo=$(jq -nc --arg a "$NEUTRON_PROBE" '{src_callback:{address:$a}}')
  seq=$(probe_send neutron "$NEUTRON_PROBE" "$(addr wasmd)" "$(channel neutron)" "100untrn" "$memo")
  [ -n "$seq" ] || { echo "FAIL s11: probe_send returned empty sequence"; return 1; }
  poll_stat_gt neutron "$NEUTRON_PROBE" ack "$a0" 60 \
    || { echo "FAIL s11: timeout waiting for src_callback ack on neutron (seq=$seq)"; return 1; }
  a1=$(stat neutron "$NEUTRON_PROBE" ack)
  [ "$a1" -eq $((a0+1)) ] || { echo "FAIL s11: ack $a0->$a1 (expected $((a0+1)))"; return 1; }
  echo "PASS s11 (ack $a0->$a1, seq=$seq)"
}

# rejected by IBCSendPacketCallback (wasmd) / srcCallbackCalldataGuard (neutron) at send time
s12(){
  local cd memo_w out_w memo_n out_n
  cd=$(hexcalldata '{"record":{}}')

  # wasmd side
  memo_w=$(jq -nc --arg a "$WASMD_PROBE" --arg c "$cd" '{src_callback:{address:$a,calldata:$c}}')
  out_w=$(probe_send wasmd "$WASMD_PROBE" "$(addr neutron)" "$(channel wasmd)" "100stake" "$memo_w" 2>&1) || true
  echo "$out_w" | grep -q "src_callback must not contain a calldata field" \
    || { echo "FAIL s12 (wasmd): expected calldata rejection, got: $(echo "$out_w" | tail -3)"; return 1; }

  # neutron side
  memo_n=$(jq -nc --arg a "$NEUTRON_PROBE" --arg c "$cd" '{src_callback:{address:$a,calldata:$c}}')
  out_n=$(probe_send neutron "$NEUTRON_PROBE" "$(addr wasmd)" "$(channel neutron)" "100untrn" "$memo_n" 2>&1) || true
  echo "$out_n" | grep -q "src_callback must not contain a calldata field" \
    || { echo "FAIL s12 (neutron): expected calldata rejection, got: $(echo "$out_n" | tail -3)"; return 1; }

  echo "PASS s12 (calldata rejected at send on both chains)"
}

# neutron x/transfer module fires sudo on any contract sender after ack; memo-independent
# (neutron removed Hooks-src ibc_callback → see neutron x/ibc-hooks/README.md)
s13(){
  local l0 l1 seq
  l0=$(stat neutron "$NEUTRON_PROBE" lifecycle)
  seq=$(probe_send neutron "$NEUTRON_PROBE" "$(addr wasmd)" "$(channel neutron)" "100untrn" "")
  [ -n "$seq" ] || { echo "FAIL s13: probe_send returned empty sequence"; return 1; }
  poll_stat_gt neutron "$NEUTRON_PROBE" lifecycle "$l0" 60 \
    || { echo "FAIL s13: timeout waiting for neutron Transfer sudo lifecycle (seq=$seq)"; return 1; }
  l1=$(stat neutron "$NEUTRON_PROBE" lifecycle)
  [ "$l1" -eq $((l0+1)) ] || { echo "FAIL s13: lifecycle $l0->$l1 (expected $((l0+1)))"; return 1; }
  echo "PASS s13 (neutron x/transfer sudo memo-independent; lifecycle $l0->$l1, seq=$seq)"
}

# IBCDedupMiddleware.SendPacket rejects ibc_callback+src_callback at send time
s14(){
  local memo out
  memo=$(jq -nc --arg a "$NEUTRON_PROBE" '{ibc_callback:$a,src_callback:{address:$a}}')
  out=$(probe_send neutron "$NEUTRON_PROBE" "$(addr wasmd)" "$(channel neutron)" "100untrn" "$memo" 2>&1) || true
  echo "$out" | grep -q "memo must not contain both ibc_callback" \
    || { echo "FAIL s14: expected dedup collision rejection, got: $(echo "$out" | tail -3)"; return 1; }
  echo "PASS s14 (dedup rejected ibc_callback+src_callback send on neutron)"
}

s15(){
  local t0 t1 seq memo hermes_pid
  t0=$(stat wasmd "$WASMD_PROBE" timeout)
  memo=$(jq -nc --arg a "$WASMD_PROBE" '{src_callback:{address:$a}}')

  # Stop hermes auto-relay
  hermes_pid=$(docker exec hermes pgrep -x hermes 2>/dev/null || true)
  if [ -n "$hermes_pid" ]; then
    docker exec hermes kill "$hermes_pid" 2>/dev/null || true
    sleep 2
  fi

  # Send with 10s timeout (needs timeout_seconds field in probe Transfer)
  seq=$(probe_send wasmd "$WASMD_PROBE" "$(addr neutron)" "$(channel wasmd)" "100stake" "$memo" 10)
  [ -n "$seq" ] || {
    # Restart hermes before failing
    docker exec -d hermes hermes --config /home/hermes/.hermes/config.toml start
    echo "FAIL s15: probe_send returned empty sequence"; return 1;
  }

  # Wait for the timeout to expire (10s timeout + ~6 extra seconds for block inclusion)
  sleep 18

  # Relay the timed-out packet (clear packets on the source chain submits the timeout tx)
  docker exec hermes hermes --config /home/hermes/.hermes/config.toml clear packets \
    --chain wasmd-test --port transfer --channel "$WASMD_CHANNEL" 2>&1 | tail -5

  poll_stat_gt wasmd "$WASMD_PROBE" timeout "$t0" 45 \
    || {
      docker exec -d hermes hermes --config /home/hermes/.hermes/config.toml start
      echo "FAIL s15: timeout waiting for src_callback timeout on wasmd (seq=$seq)"; return 1;
    }
  t1=$(stat wasmd "$WASMD_PROBE" timeout)
  [ "$t1" -eq $((t0+1)) ] || {
    docker exec -d hermes hermes --config /home/hermes/.hermes/config.toml start
    echo "FAIL s15: timeout counter $t0->$t1 (expected $((t0+1)))"; return 1;
  }

  # Restart hermes so the harness is left in a relaying state
  docker exec -d hermes hermes --config /home/hermes/.hermes/config.toml start
  sleep 3

  echo "PASS s15 (timeout $t0->$t1, seq=$seq; hermes restarted)"
}

run_src(){
  local rc=0
  for s in s10 s11 s12 s13 s14 s15; do
    $s || rc=1
  done
  return $rc
}
