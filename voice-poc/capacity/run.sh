#!/usr/bin/env bash
# Isolated group-voice capacity PoC on a throwaway GitHub-hosted Linux runner. Dev keys only. Never on production.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$PWD/poc-out}
DUR=${DUR:-80}          # seconds each lk load-test runs
WIN_START=${WIN_START:-25}  # measurement window inside each phase (skips joins/ramp)
WIN_END=${WIN_END:-75}
STAGGER=${STAGGER:-0.25}   # seconds between room starts (avoids an unrealistic join storm)
SRV_IMG=livekit/livekit-server@sha256:89ca9ce0791e18d6e03bf6e2c49ceb27e1c754eae8bd50c989386c1a5963791a
CLI_IMG=livekit/livekit-cli@sha256:25b750bc0ad2045d96e06801a7215968bcbe41dc3f3c42bb75fa1787a80d5328
mkdir -p "$OUT/raw" "$OUT/bin" "$OUT/cfg"
RAW=$OUT/raw
log() { echo "[$(date -u +%T)] $*" | tee -a "$RAW/run.log"; }

# ---------- 0. hardware ----------
{
  echo "nproc: $(nproc)"
  echo "cpu: $(lscpu | sed -n 's/^Model name:[[:space:]]*//p')"
  echo "mem: $(free -m | awk '/^Mem:/{print $2" MiB"}')"
  echo "kernel: $(uname -r)"; . /etc/os-release; echo "os: $PRETTY_NAME"
  echo "docker: $(docker version --format '{{.Server.Version}}')"
} > "$RAW/hardware-summary.txt"
{ lscpu; free -m; cat /proc/meminfo | head -5; } > "$RAW/hardware.txt"
cat "$RAW/hardware-summary.txt"

# ---------- 1. pull by digest and verify ----------
for img in "$SRV_IMG" "$CLI_IMG"; do
  docker pull -q "$img" >/dev/null || { log "pull failed $img"; exit 1; }
  want=${img#*@}
  got=$(docker inspect --format '{{json .RepoDigests}}' "$img")
  echo "$img RepoDigests=$got" | tee -a "$RAW/digests.txt"
  grep -q "$want" <<<"$got" || { log "DIGEST MISMATCH $img"; exit 1; }
done
for t in livekit/livekit-server:v1.13.10 livekit/livekit-cli:v2.19.4; do
  echo "$t tag currently resolves to: $(docker buildx imagetools inspect "$t" --format '{{json .Manifest.Digest}}' 2>&1)" >> "$RAW/digests.txt"
done
cid=$(docker create "$CLI_IMG"); docker cp "$cid:/lk" "$OUT/bin/lk"; docker rm "$cid" >/dev/null
LK=$OUT/bin/lk
echo "lk binary (extracted from the verified image) sha256 $(sha256sum "$LK" | cut -d' ' -f1)" >> "$RAW/digests.txt"
"$LK" --version >> "$RAW/digests.txt" 2>&1
docker run --rm "$SRV_IMG" --version >> "$RAW/digests.txt" 2>&1
docker run --rm "$SRV_IMG" --help > "$RAW/server-help.txt" 2>&1
"$LK" perf load-test --help > "$RAW/lk-load-test-help.txt" 2>&1
"$LK" token create --help > "$RAW/lk-token-create-help.txt" 2>&1
"$LK" room join --help > "$RAW/lk-room-join-help.txt" 2>&1
cat "$RAW/digests.txt"

# ---------- 2. server with the proposed production limits ----------
cp "$HERE/livekit.yaml" "$OUT/cfg/"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=turn.poc.local \
  -keyout "$OUT/cfg/turn.key" -out "$OUT/cfg/turn.crt" 2>/dev/null
chmod 644 "$OUT/cfg/turn.key"
start_server() {
  docker rm -f lk >/dev/null 2>&1
  docker run -d --name lk --cpus=1.5 --memory=2g --cpu-shares=256 --network host \
    -v "$OUT/cfg:/etc/lk:ro" "$SRV_IMG" --config /etc/lk/livekit.yaml --dev --bind 0.0.0.0 >/dev/null
  for _ in $(seq 1 30); do curl -fs http://127.0.0.1:7880 >/dev/null && break; sleep 1; done
  CID=$(docker inspect -f '{{.Id}}' lk)
  CG=$(find /sys/fs/cgroup -maxdepth 3 -type d -name "docker-$CID.scope" | head -1)
  [ -n "$CG" ] || CG=$(find /sys/fs/cgroup -maxdepth 4 -type d -name "$CID" | head -1)
  echo "$CG" > "$RAW/.cgroup"
  log "server up, cgroup=$CG limits: $(docker inspect -f 'NanoCpus={{.HostConfig.NanoCpus}} Memory={{.HostConfig.Memory}} CpuShares={{.HostConfig.CpuShares}}' lk)"
}
start_server
docker logs lk > "$RAW/server-startup.log" 2>&1

# ---------- sampler (every 2 s) ----------
echo "ts,cg_usec,cg_mem,lo_rx,d0_rx,udp_in,udp_out,udp_inerr,udp_rcvbuf,udp_sndbuf,cpu_busy,cpu_all,load1,ds_cpu,ds_mem" > "$RAW/samples.csv"
sampler() {
  while [ -f "$RAW/.sampling" ]; do
    ts=$(date +%s.%N)
    CG=$(cat "$RAW/.cgroup")
    u=$(awk '/^usage_usec/{print $2}' "$CG/cpu.stat" 2>/dev/null || echo 0)
    m=$(cat "$CG/memory.current" 2>/dev/null || echo 0)
    lo=$(awk '/^ *lo:/{sub(/^ *lo:/,""); split($0,a," "); print a[1]}' /proc/net/dev)
    d0=$(awk '/^ *docker0:/{sub(/^ *docker0:/,""); split($0,a," "); print a[1]}' /proc/net/dev); d0=${d0:-0}
    udp=$(awk '/^Udp:/{n++; if(n==2) print $2","$5","$4","$6","$7}' /proc/net/snmp)
    cpu=$(awk '/^cpu /{b=$2+$3+$4+$7+$8+$9; a=b+$5+$6; print b","a}' /proc/stat)
    l1=$(cut -d' ' -f1 /proc/loadavg)
    ds=$(docker stats --no-stream --format '{{.CPUPerc}};{{.MemUsage}}' lk 2>/dev/null | tr -d ' ,')
    echo "$ts,$u,$m,$lo,$d0,$udp,$cpu,$l1,${ds%%;*},${ds#*;}" >> "$RAW/samples.csv"
    sleep 1
  done
}
touch "$RAW/.sampling"; sampler & SAMPLER=$!
echo "name,N,pattern,rooms,mapping,start,end,mstart,mend,srv_errors" > "$RAW/phases.csv"

# run_phase NAME N PATTERN ROOMS PUBS SUBS [extra rooms-side command hook]
run_phase() {
  local name=$1 n=$2 pattern=$3 rooms=$4 pubs=$5 subs=$6 mapping=$7
  mkdir -p "$RAW/$name"
  local t0; t0=$(date +%s.%N); local since; since=$(date -u +%Y-%m-%dT%H:%M:%S)
  curl -fs http://127.0.0.1:6789/metrics > "$RAW/$name/metrics-start.txt" 2>/dev/null
  log "phase $name: N=$n rooms=$rooms pubs=$pubs subs=$subs"
  local pids=(); HOOK_PIDS=""
  for i in $(seq 1 "$rooms"); do
    "$LK" --url ws://127.0.0.1:7880 --api-key devkey --api-secret secret perf load-test --room "$name-r$i" \
      --audio-publishers "$pubs" --subscribers "$subs" --duration "${DUR}s" --num-per-second 10 --layout 3x3 \
      > "$RAW/$name/r$i.txt" 2>&1 & pids+=($!)
    sleep "$STAGGER"
  done
  [ -n "${PHASE_HOOK:-}" ] && eval "$PHASE_HOOK"
  wait "${pids[@]}" ${HOOK_PIDS:-}
  local t1; t1=$(date +%s.%N)
  curl -fs http://127.0.0.1:6789/metrics > "$RAW/$name/metrics-end.txt" 2>/dev/null
  local e; e=$(docker logs --since "$since" lk 2>&1 | grep -cE '\bERROR\b|"level":"error"')
  local ws; ws=$(awk -v r="$rooms" -v s="$STAGGER" -v w="$WIN_START" 'BEGIN{x=r*s+15; print (x>w?x:w)}')
  awk -v a="$t0" -v b="$t1" -v s="$ws" -v w="$WIN_END" -v nm="$name" -v N="$n" -v p="$pattern" -v r="$rooms" -v mp="$mapping" -v e="$e" \
    'BEGIN{ms=a+s; me=a+w; if(me>b) me=b; printf "%s,%s,%s,%s,%s,%.3f,%.3f,%.3f,%.3f,%s\n", nm,N,p,r,mp,a,b,ms,me,e}' >> "$RAW/phases.csv"
  sleep 8
}

# ---------- 5 (first, on a fresh server). permission test M6 ----------
log "permission test"
python3 -m venv "$OUT/venv" && "$OUT/venv/bin/pip" install -q livekit livekit-api > "$RAW/pip.log" 2>&1
"$OUT/venv/bin/pip" show livekit livekit-api 2>/dev/null | grep -E '^(Name|Version)' > "$RAW/perm-sdk-versions.txt"
timeout 120 "$OUT/venv/bin/python" -I "$HERE/perm_test.py" ws://127.0.0.1:7880 > "$RAW/perm.json" 2> "$RAW/perm.stderr" || echo "perm test exit $?" >> "$RAW/perm.json"
cat "$RAW/perm-sdk-versions.txt" >> "$RAW/perm.json"
docker logs lk 2>&1 | grep -iE 'perm-client|permission|not allowed|cannot publish' | tail -20 > "$RAW/perm-server.log"
echo "--- server log lines about the permission test ---" >> "$RAW/perm.json"; cat "$RAW/perm-server.log" >> "$RAW/perm.json"
cat "$RAW/perm.json"

# ---------- 3/4. capacity steps ----------
for N in 8 24 40 80 200 400 800; do
  if [ "$N" = 800 ]; then
    python3 "$HERE/analyze.py" gate "$OUT" "cap-400-" | tee -a "$RAW/run.log" || { log "800 skipped: the 400 step hit >=140% CPU or errors"; break; }
  fi
  R=$((N / 8))
  run_phase "cap-$N-realistic" "$N" realistic "$R" 2 6 "2 audio pub + 6 sub (8 participants)"
  run_phase "cap-$N-worst" "$N" worst "$R" 8 8 "8 audio pub + 8 sub (16 conns; publishers do not subscribe in lk, 8x8=64 egress streams vs 8x7=56 real)"
done

# ---------- TURN (built-in, dedicated ports) ----------
log "TURN test"
start_server
GW=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')
SUBNET=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Subnet}}')
turn_subs() { # rooms prefix -> starts bridge-network subscriber containers
  HOOK_PIDS=""
  for i in $(seq 1 "$1"); do
    docker run --rm --add-host turn.poc.local:host-gateway "$CLI_IMG" --url "ws://$GW:7880" --api-key devkey --api-secret secret \
      perf load-test --room "$2-r$i" --subscribers 2 --layout 3x3 --duration "$((DUR - 5))s" > "$RAW/$2/bridge-r$i.txt" 2>&1 &
    HOOK_PIDS="$HOOK_PIDS $!"
  done
}
TR=5
mkdir -p "$RAW/turn-direct" "$RAW/turn-relayed"
PHASE_HOOK='sleep 3; turn_subs $TR turn-direct' run_phase turn-direct 40 turn "$TR" 2 4 "2 pub + 4 sub host + 2 sub in docker bridge, direct UDP"
sudo iptables -I INPUT 1 -i docker0 -s "$SUBNET" -p udp --dport 3479 -j ACCEPT
sudo iptables -I INPUT 2 -i docker0 -s "$SUBNET" -p udp -j DROP
sudo iptables -I INPUT 3 -i docker0 -s "$SUBNET" -p tcp --dport 7881 -j DROP
PHASE_HOOK='sleep 3; turn_subs $TR turn-relayed' run_phase turn-relayed 40 turn "$TR" 2 4 "2 pub + 4 sub host + 2 sub in docker bridge, direct UDP+TCP7881 blocked => TURN/UDP 3479 only"
{
  echo "bridge gateway $GW subnet $SUBNET"
  echo "--- iptables counters after the relayed phase (rule 1 = TURN/UDP 3479 accepted, 2 = other UDP dropped, 3 = ICE/TCP 7881 dropped) ---"
  sudo iptables -L INPUT -v -n -x | head -6
  echo "--- bridge subscriber summaries (relayed) ---"
  for f in "$RAW"/turn-relayed/bridge-r*.txt; do grep -E 'Total|could not|error' "$f" | tail -3; done
  echo "--- bridge subscriber summaries (direct) ---"
  for f in "$RAW"/turn-direct/bridge-r*.txt; do grep -E 'Total|could not|error' "$f" | tail -3; done
  echo "--- server log lines mentioning turn/relay ---"
  docker logs lk 2>&1 | grep -iE 'turn|relay' | head -20
} > "$RAW/turn-evidence.txt" 2>&1
sudo iptables -D INPUT 3; sudo iptables -D INPUT 2; sudo iptables -D INPUT 1
cat "$RAW/turn-evidence.txt"

# ---------- 6. impairment sample on lo ----------
log "impairment"
sudo tc qdisc add dev lo root netem delay 40ms 10ms loss 2%
sudo tc qdisc show dev lo > "$RAW/impairment.txt"
run_phase "netem-8-realistic" 8 realistic 1 2 6 "2 pub + 6 sub, lo netem delay 40ms 10ms loss 2%"
sudo tc qdisc del dev lo root
echo "--- lk output (impaired) ---" >> "$RAW/impairment.txt"
grep -A30 'Subscriber summaries' "$RAW/netem-8-realistic/r1.txt" >> "$RAW/impairment.txt"
echo "--- lk output (same room, no impairment, step N=8) ---" >> "$RAW/impairment.txt"
grep -A30 'Subscriber summaries' "$RAW/cap-8-realistic/r1.txt" >> "$RAW/impairment.txt"

rm -f "$RAW/.sampling"; wait $SAMPLER 2>/dev/null
docker logs lk > "$RAW/server-final.log" 2>&1
docker rm -f lk >/dev/null
python3 "$HERE/analyze.py" report "$OUT"
