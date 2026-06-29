#!/usr/bin/env bash
# scenarios/recv.sh – receive-side IBC scenarios 1-9

calls_len(){ q "$1" "$2" '{"calls":{}}' | jq '.calls|length'; }
stat(){      q "$1" "$2" '{"stats":{}}' | jq -r ".$3"; }
hexcalldata(){ printf '%s' "$1" | xxd -p | tr -d '\n'; }

# voucher_denom <chain> <base_denom> <channel>
voucher_denom(){
  local chain=$1 base=$2 ch=$3 hash
  hash=$(ce "$chain" q ibc-transfer denom-hash "transfer/${ch}/${base}" | jq -r .hash)
  echo "ibc/${hash}"
}

poll_calls_gt(){
  local c=$1 p=$2 floor=$3 timeout=${4:-45} elapsed=0 n
  while [ "$elapsed" -lt "$timeout" ]; do
    n=$(calls_len "$c" "$p")
    [ "$n" -gt "$floor" ] && return 0
    sleep 2; elapsed=$((elapsed+2))
  done
  return 1
}

poll_dest_gt(){
  local c=$1 p=$2 floor=$3 timeout=${4:-45} elapsed=0 n
  while [ "$elapsed" -lt "$timeout" ]; do
    n=$(stat "$c" "$p" dest)
    [ "$n" -gt "$floor" ] && return 0
    sleep 2; elapsed=$((elapsed+2))
  done
  return 1
}

# poll_bal_gt: balance drops on send, then rises again after error-ack refund
poll_bal_gt(){
  local c=$1 a=$2 d=$3 floor=$4 timeout=${5:-60} elapsed=0 n
  while [ "$elapsed" -lt "$timeout" ]; do
    n=$(bal "$c" "$a" "$d")
    [ "$n" -gt "$floor" ] && return 0
    sleep 2; elapsed=$((elapsed+2))
  done
  return 1
}

s1(){
  local before after sender want cd memo d0 d1
  before=$(calls_len wasmd "$WASMD_PROBE")
  d0=$(stat wasmd "$WASMD_PROBE" dest)
  cd=$(hexcalldata '{"record":{}}')
  memo=$(jq -nc --arg a "$WASMD_PROBE" --arg c "$cd" '{dest_callback:{address:$a,calldata:$c}}')
  transfer neutron 100 untrn "$WASMD_PROBE" "$memo"
  poll_calls_gt wasmd "$WASMD_PROBE" "$before" || { echo "FAIL s1: timeout waiting for dest callback"; return 1; }
  after=$(calls_len wasmd "$WASMD_PROBE")
  [ "$after" -eq $((before+1)) ] || { echo "FAIL s1: calls $before->$after (expected $((before+1)))"; return 1; }
  sender=$(q wasmd "$WASMD_PROBE" '{"calls":{}}' | jq -r '.calls[-1].sender')
  want=$(derive_intermediate wasm "$WASMD_CHANNEL" "$(addr neutron)")
  [ "$sender" = "$want" ] || { echo "FAIL s1: sender=$sender != derived=$want"; return 1; }
  d1=$(stat wasmd "$WASMD_PROBE" dest)
  [ "$d1" -eq "$d0" ] || { echo "FAIL s1: stats.dest advanced ($d0->$d1); dest-fallback must not fire with calldata"; return 1; }
  echo "PASS s1"
}

s2(){
  local cd memo b0 b_sent b1 n0 n1 lost amount=1000000
  cd=$(hexcalldata '{"fail":{}}')
  memo=$(jq -nc --arg a "$WASMD_PROBE" --arg c "$cd" '{dest_callback:{address:$a,calldata:$c}}')
  b0=$(bal neutron "$(addr neutron)" untrn)
  n0=$(calls_len wasmd "$WASMD_PROBE")
  transfer neutron "$amount" untrn "$WASMD_PROBE" "$memo"
  # Balance drops once tx lands; wait for error-ack refund to bring it back above b_sent
  b_sent=$(bal neutron "$(addr neutron)" untrn)
  poll_bal_gt neutron "$(addr neutron)" untrn "$b_sent" 60 \
    || { echo "FAIL s2: timeout waiting for error-ack refund (balance stuck at $b_sent)"; return 1; }
  b1=$(bal neutron "$(addr neutron)" untrn)
  n1=$(calls_len wasmd "$WASMD_PROBE")
  [ "$n1" -eq "$n0" ] || { echo "FAIL s2: calls advanced ($n0->$n1); callback should have failed"; return 1; }
  lost=$(( b0 - b1 ))
  [ "$lost" -lt "$amount" ] \
    || { echo "FAIL s2: lost=$lost >= amount=$amount; refund did not arrive (funds not returned)"; return 1; }
  echo "PASS s2 (balance $b0->$b1, lost=$lost < amount=$amount, calls unchanged)"
}

s3(){
  local memo d0 d1 n0 n1
  memo=$(jq -nc --arg a "$WASMD_PROBE" '{dest_callback:{address:$a}}')
  d0=$(stat wasmd "$WASMD_PROBE" dest)
  n0=$(calls_len wasmd "$WASMD_PROBE")
  transfer neutron 100 untrn "$WASMD_PROBE" "$memo"
  poll_dest_gt wasmd "$WASMD_PROBE" "$d0" || { echo "FAIL s3: timeout waiting for ibc_destination_callback"; return 1; }
  d1=$(stat wasmd "$WASMD_PROBE" dest)
  n1=$(calls_len wasmd "$WASMD_PROBE")
  [ "$d1" -eq $((d0+1)) ] || { echo "FAIL s3: stats.dest $d0->$d1 (expected $((d0+1)))"; return 1; }
  [ "$n1" -eq "$n0" ] || { echo "FAIL s3: calls advanced ($n0->$n1); unexpected execute"; return 1; }
  echo "PASS s3"
}

s4(){
  local before after sender want cd memo d0 d1
  before=$(calls_len neutron "$NEUTRON_PROBE")
  d0=$(stat neutron "$NEUTRON_PROBE" dest)
  cd=$(hexcalldata '{"record":{}}')
  memo=$(jq -nc --arg a "$NEUTRON_PROBE" --arg c "$cd" '{dest_callback:{address:$a,calldata:$c}}')
  transfer wasmd 100 stake "$NEUTRON_PROBE" "$memo"
  poll_calls_gt neutron "$NEUTRON_PROBE" "$before" || { echo "FAIL s4: timeout waiting for dest callback"; return 1; }
  after=$(calls_len neutron "$NEUTRON_PROBE")
  [ "$after" -eq $((before+1)) ] || { echo "FAIL s4: calls $before->$after"; return 1; }
  sender=$(q neutron "$NEUTRON_PROBE" '{"calls":{}}' | jq -r '.calls[-1].sender')
  want=$(derive_intermediate neutron "$NEUTRON_CHANNEL" "$(addr wasmd)")
  [ "$sender" = "$want" ] || { echo "FAIL s4: sender=$sender != derived=$want"; return 1; }
  d1=$(stat neutron "$NEUTRON_PROBE" dest)
  [ "$d1" -eq "$d0" ] || { echo "FAIL s4: stats.dest advanced ($d0->$d1); dest-fallback must not fire with calldata"; return 1; }
  echo "PASS s4"
}

s5(){
  local before after memo
  before=$(calls_len neutron "$NEUTRON_PROBE")
  memo=$(jq -nc --arg a "$NEUTRON_PROBE" '{wasm:{contract:$a,msg:{record:{}}}}')
  transfer wasmd 100 stake "$NEUTRON_PROBE" "$memo"
  poll_calls_gt neutron "$NEUTRON_PROBE" "$before" || { echo "FAIL s5: timeout; hooks did not dispatch execute on neutron"; return 1; }
  after=$(calls_len neutron "$NEUTRON_PROBE")
  [ "$after" -eq $((before+1)) ] || { echo "FAIL s5: calls $before->$after"; return 1; }
  echo "PASS s5"
}

s6(){
  local n0 n1 rb0 rb1 memo voucher
  voucher=$(voucher_denom wasmd untrn "$WASMD_CHANNEL")
  rb0=$(bal wasmd "$WASMD_PROBE" "$voucher")
  n0=$(calls_len wasmd "$WASMD_PROBE")
  memo=$(jq -nc --arg a "$WASMD_PROBE" '{wasm:{contract:$a,msg:{record:{}}}}')
  transfer neutron 100 untrn "$WASMD_PROBE" "$memo"
  # Anchor to relay completion: poll until voucher balance increases
  poll_bal_gt wasmd "$WASMD_PROBE" "$voucher" "$rb0" 60 \
    || { echo "FAIL s6: timeout waiting for voucher to arrive at WASMD_PROBE (relay did not deliver)"; return 1; }
  rb1=$(bal wasmd "$WASMD_PROBE" "$voucher")
  n1=$(calls_len wasmd "$WASMD_PROBE")
  [ "$n1" -eq "$n0" ] \
    || { echo "FAIL s6: calls advanced ($n0->$n1); hooks middleware unexpectedly present on wasmd"; return 1; }
  echo "PASS s6 (wasm memo ignored on wasmd; calls unchanged $n0; voucher $rb0->$rb1)"
}

s7(){
  local n0 n1 memo_h memo_c sh sc want
  n0=$(calls_len neutron "$NEUTRON_PROBE")
  # First: Hooks-recv
  memo_h=$(jq -nc --arg a "$NEUTRON_PROBE" '{wasm:{contract:$a,msg:{record:{}}}}')
  transfer wasmd 100 stake "$NEUTRON_PROBE" "$memo_h"
  poll_calls_gt neutron "$NEUTRON_PROBE" "$n0" || { echo "FAIL s7: timeout on hooks-recv"; return 1; }
  sh=$(q neutron "$NEUTRON_PROBE" '{"calls":{}}' | jq -r '.calls[-1].sender')
  n1=$(calls_len neutron "$NEUTRON_PROBE")
  # Second: Callbacks+-recv
  memo_c=$(jq -nc --arg a "$NEUTRON_PROBE" --arg c "$(hexcalldata '{"record":{}}')" \
    '{dest_callback:{address:$a,calldata:$c}}')
  transfer wasmd 100 stake "$NEUTRON_PROBE" "$memo_c"
  poll_calls_gt neutron "$NEUTRON_PROBE" "$n1" || { echo "FAIL s7: timeout on cbplus-recv"; return 1; }
  sc=$(q neutron "$NEUTRON_PROBE" '{"calls":{}}' | jq -r '.calls[-1].sender')
  want=$(derive_intermediate neutron "$NEUTRON_CHANNEL" "$(addr wasmd)")
  [ "$sh" = "$sc" ] || { echo "FAIL s7: hooks_sender=$sh != cbplus_sender=$sc (not identical)"; return 1; }
  [ "$sh" = "$want" ] || { echo "FAIL s7: sender=$sh != derived=$want"; return 1; }
  echo "PASS s7 (identical info.sender: $sh)"
}

s8(){
  local n0 d0 n1 d1 memo b0 b_sent b1 lost amount=1000000
  n0=$(calls_len neutron "$NEUTRON_PROBE")
  d0=$(stat neutron "$NEUTRON_PROBE" dest)
  b0=$(bal wasmd "$(addr wasmd)" stake)
  memo=$(jq -nc --arg a "$NEUTRON_PROBE" \
    '{wasm:{contract:$a,msg:{record:{}}},dest_callback:{address:$a}}')
  transfer wasmd "$amount" stake "$NEUTRON_PROBE" "$memo"
  # Balance drops once tx lands; wait for error-ack refund to bring it back above b_sent
  b_sent=$(bal wasmd "$(addr wasmd)" stake)
  poll_bal_gt wasmd "$(addr wasmd)" stake "$b_sent" 60 \
    || { echo "FAIL s8: timeout waiting for error-ack refund from dedup rejection"; return 1; }
  b1=$(bal wasmd "$(addr wasmd)" stake)
  n1=$(calls_len neutron "$NEUTRON_PROBE")
  d1=$(stat neutron "$NEUTRON_PROBE" dest)
  [ "$n1" -eq "$n0" ] || { echo "FAIL s8: calls advanced ($n0->$n1); dedup did not reject"; return 1; }
  [ "$d1" -eq "$d0" ] || { echo "FAIL s8: stats.dest advanced ($d0->$d1); dedup did not reject"; return 1; }
  lost=$(( b0 - b1 ))
  [ "$lost" -lt "$amount" ] \
    || { echo "FAIL s8: lost=$lost >= amount=$amount; no refund (dedup error-ack may be missing)"; return 1; }
  echo "PASS s8 (dedup rejected collision; refund confirmed: lost=$lost < amount=$amount)"
}

# wasmd has no Dedup → wasm key ignored, dest_callback honored
s9(){
  local d0 d1 n0 n1 memo
  d0=$(stat wasmd "$WASMD_PROBE" dest)
  n0=$(calls_len wasmd "$WASMD_PROBE")
  memo=$(jq -nc --arg a "$WASMD_PROBE" \
    '{wasm:{contract:$a,msg:{record:{}}},dest_callback:{address:$a}}')
  transfer neutron 100 untrn "$WASMD_PROBE" "$memo"
  poll_dest_gt wasmd "$WASMD_PROBE" "$d0" || { echo "FAIL s9: timeout waiting for dest_callback on wasmd"; return 1; }
  d1=$(stat wasmd "$WASMD_PROBE" dest)
  n1=$(calls_len wasmd "$WASMD_PROBE")
  [ "$d1" -eq $((d0+1)) ] || { echo "FAIL s9: stats.dest $d0->$d1 (expected $((d0+1)))"; return 1; }
  [ "$n1" -eq "$n0" ] || { echo "FAIL s9: calls advanced ($n0->$n1); wasm key was executed on wasmd"; return 1; }
  echo "PASS s9 (no dedup on wasmd; dest_callback honored; wasm ignored)"
}

run_recv(){
  local rc=0
  for s in s1 s2 s3 s4 s5 s6 s7 s8 s9; do
    $s || rc=1
  done
  return $rc
}
