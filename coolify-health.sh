r/bin/env bash
# coolify-health-collector.sh

set -eo pipefail

# ---------- Host: CPU%  ----------
read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
sleep 1
read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat
t1=$((u1 + n1 + s1 + i1 + w1 + q1 + sq1 + st1))
t2=$((u2 + n2 + s2 + i2 + w2 + q2 + sq2 + st2))
dt=$((t2 - t1))
didle=$(( (i2 - i1) + (w2 - w1) ))
cpu_pct=0
if [ "$dt" -gt 0 ]; then
  cpu_pct=$(( 100 * (dt - didle) / dt ))
fi

# ---------- Host: memory, disk, load, uptime ----------
read -r mem_used mem_total < <(free -b | awk '/^Mem:/ {print $3, $2}')
read -r disk_used disk_total < <(df -B1 --output=used,size / | tail -1 | awk '{print $1, $2}')
load=$(cut -d' ' -f1-3 /proc/loadavg | tr ' ' ',')
uptime_s=$(cut -d. -f1 /proc/uptime)
ts=$(date +%s)

# ---------- Containers: docker stats (running) ----------
declare -A S_CPU S_MEMPCT S_MEMUSE S_NET S_BLK S_PIDS
while IFS='|' read -r name cpup memp memu net blk pids; do
  [ -z "$name" ] && continue
  S_CPU["$name"]="${cpup%\%}"
  S_MEMPCT["$name"]="${memp%\%}"
  S_MEMUSE["$name"]="$memu"
  S_NET["$name"]="$net"
  S_BLK["$name"]="$blk"
  S_PIDS["$name"]="$pids"
done < <(docker stats --no-stream \
  --format '{{.Name}}|{{.CPUPerc}}|{{.MemPerc}}|{{.MemUsage}}|{{.NetIO}}|{{.BlockIO}}|{{.PIDs}}')

# ---------- Containers: state, health, restarts (all) ----------
containers_json=""
ids=$(docker ps -aq)
if [ -n "$ids" ]; then
  while IFS='|' read -r name status health restarts started image; do
    name="${name#/}"
    cpu="${S_CPU[$name]:-null}"
    mempct="${S_MEMPCT[$name]:-null}"
    memuse="${S_MEMUSE[$name]:-}"
    net="${S_NET[$name]:-}"
    blk="${S_BLK[$name]:-}"
    pids="${S_PIDS[$name]:-null}"
    entry=$(printf '{"name":"%s","image":"%s","status":"%s","health":"%s","restarts":%s,"started":"%s","cpu_pct":%s,"mem_pct":%s,"mem_usage":"%s","net_io":"%s","block_io":"%s","pids":%s}' \
      "$name" "$image" "$status" "$health" "$restarts" "$started" \
      "$cpu" "$mempct" "$memuse" "$net" "$blk" "$pids")
    containers_json+="${containers_json:+,}$entry"
  done < <(echo "$ids" | xargs docker inspect \
    --format '{{.Name}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}|{{.State.StartedAt}}|{{.Config.Image}}')
fi

# ---------- Output ----------
printf '{"ts":%s,"host":{"cpu_pct":%s,"mem_used":%s,"mem_total":%s,"disk_used":%s,"disk_total":%s,"load":[%s],"uptime_s":%s},"containers":[%s]}\n' \
  "$ts" "$cpu_pct" "$mem_used" "$mem_total" "$disk_used" "$disk_total" "$load" "$uptime_s" "$containers_json"