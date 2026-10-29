#!/bin/bash
# poll function cost per call as one shard grows (SOLAR-210). For each login count
# N: leave N fake logins active, warm the inverter list, then on the next ordinary
# minute call poll once and record wall time, CPU (edge container's cgroup delta)
# and what it wrote.
#   load-test/poll-cpu.sh <service-key-file> 1 25 100 250 500
set -euo pipefail
KEY=$(cat "$1"); shift
q() { docker exec solar-loadtest-client psql -h solar-loadtest-db -U postgres -Atq -v ON_ERROR_STOP=1 -c "$1"; }
cpu() { docker exec solar-loadtest-edge sh -c 'grep usage_usec /sys/fs/cgroup/cpu.stat' | awk '{print $2}'; }
poll() { curl -s -m 450 -X POST http://127.0.0.1:54402/poll -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d '{"shard":0,"shards":1}' -D /dev/stderr; }

for N in "$@"; do
  q "select loadtest.add_fleet($((N * 2)))" >/dev/null
  q "update private.sunsynk_accounts set status = case when sunsynk_username ~ '^lt' and substr(sunsynk_username, 3)::int <= $N then 'active' else 'disabled' end, last_error = null" >/dev/null
  poll 2>/dev/null >/dev/null   # first call per login reads the inverter list
  # Wait for the next minute that is not a 10-minute list refresh.
  while :; do s=$(date +%s); next=$(( (s / 60 + 1) * 60 )); (( (next / 60) % 10 != 0 )) && break; sleep $(( next - s + 1 )); done
  sleep $(( next - $(date +%s) + 1 ))
  c0=$(cpu); t0=$(python3 -c "import time;print(int(time.time()*1000))")
  body=$(poll 2>/tmp/solar-loadtest-h)
  t1=$(python3 -c "import time;print(int(time.time()*1000))"); c1=$(cpu)
  status=$(head -1 /tmp/solar-loadtest-h | awk '{print $2}')
  echo "{\"logins\":$N,\"status\":$status,\"wallMs\":$((t1 - t0)),\"cpuMs\":$(( (c1 - c0) / 1000 )),\"result\":$(echo "$body" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);console.log(JSON.stringify({ok:j.ok,accounts:j.accounts,succeeded:j.succeeded,readings:j.readings,error:j.error}))}catch{console.log(JSON.stringify(s.slice(0,200)))}})')}"
done
rm -f /tmp/solar-loadtest-h
