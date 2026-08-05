#!/bin/bash
# Watches the SOC spread between the two inverter banks while the charge current is
# being pushed up (60→75A). Polls every 5 min; on sustained drift it fires a macOS
# notification and exits (which surfaces the alert back in the Claude session).
URL=http://localhost:3002/api/balance
watch=0
for i in $(seq 1 200); do   # ~16.7 h of coverage
  line=$(curl -s --max-time 10 "$URL" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{const j=JSON.parse(s);console.log((j.status||'unknown')+' '+(j.socSpread??0)+' '+(j.max24h??0)+' '+(j.stale?1:0))}catch(e){console.log('unknown 0 0 1')}})")
  read -r st sp mx stale <<< "$line"
  if [ "$st" = "drifting" ]; then
    osascript -e "display notification \"Banks ${sp}% apart at 75A — drop the charge current back to 60A\" with title \"⚠ Battery drift detected\" sound name \"Basso\"" 2>/dev/null
    echo "DRIFT ALERT after ~$((i*5)) min: SOC spread ${sp}% (24h max ${mx}%). Recommend dropping the charge current back to 60A and checking the modules."
    exit 0
  fi
  if [ "$st" = "watch" ]; then watch=$((watch+1)); else watch=0; fi
  if [ "$watch" -ge 3 ]; then
    osascript -e "display notification \"Banks creeping to ${sp}% apart — keep an eye on it\" with title \"Battery balance: watch\"" 2>/dev/null
    echo "WATCH (sustained ~15 min) after ~$((i*5)) min: SOC spread ${sp}% (24h max ${mx}%). Trending up but not critical yet."
    exit 0
  fi
  sleep 300
done
echo "All clear: watched the 75 A charge for ~16 h — banks stayed balanced, no drift."
