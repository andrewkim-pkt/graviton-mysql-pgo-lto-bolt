#!/bin/bash
# g15m ADAPTATION: default cell = node 1 (96-159); numactl --membind -> --preferred (membind OOM-killed
# mysqld on this fleet; README says pin CPUs only). Otherwise verbatim.
# g15m-wb: WHOLE-BOX variant of srv-c.sh -- unpinned (CPUS empty), ulimit -n 65535 (hard limit), --innodb-numa-interleave=ON.
# Private server control for the MySQL HWPGO campaign. Runs ON <metal-host>.
#   srv-c.sh init  <basedir>   fresh datadir on the private tmpfs + root account
#   srv-c.sh start <basedir>   start mysqld pinned to 8 vCPU on node 1
#   srv-c.sh stop              clean shutdown of THIS instance only
#   srv-c.sh status
#
# Every process operation is scoped by the unique --defaults-file path, never by
# `pgrep -x mysqld`, because another agent runs its own mysqld on this same host.
set -uo pipefail

DIR=/home/ec2-user/hwpgo
CNF=$DIR/my-c.cnf
DATADIR=/mnt/ramdisk/mysqldata
SOCK=/tmp/mysql.sock
# Overridable so one script can emulate every instance size (see run-size-matrix-c.sh).
CPUS=${CPUS:-}
MEMNODE=${MEMNODE:-1}
PASS=mysql
MYPAT="defaults-file=$CNF"

log() { echo "[$(date -u +%T)] $*"; }
mypid() { pgrep -f -- "$MYPAT" | head -1; }

wait_ready() {   # $1 = basedir, $2 = timeout seconds
  local b=$1 t=${2:-900} i=0
  while [ "$i" -lt "$t" ]; do
    if "$b/bin/mysqladmin" -S "$SOCK" -uroot -p"$PASS" ping 2>/dev/null | grep -q alive; then
      log "mysqld ready after ${i}s"; return 0
    fi
    if [ -z "$(mypid)" ]; then
      log "FAIL: my mysqld exited during startup"; tail -20 "$DIR/mysqld-error.log"; return 1
    fi
    sleep 2; i=$((i+2))
  done
  log "FAIL: readiness timeout after ${t}s"; tail -20 "$DIR/mysqld-error.log"; return 1
}

stop_server() {
  local b p
  b=$(cat "$DIR/.current-basedir" 2>/dev/null || echo /opt/mysql-gcc15-base)
  p=$(mypid)
  if [ -n "$p" ]; then
    log "clean shutdown of pid $p"
    "$b/bin/mysqladmin" -S "$SOCK" -uroot -p"$PASS" shutdown 2>/dev/null
    for _ in $(seq 1 120); do [ -z "$(mypid)" ] && break; sleep 1; done
    p=$(mypid); [ -n "$p" ] && { log "still up, SIGTERM $p"; kill "$p"; sleep 10; }
  fi
  log "stopped"
}

start_pinned() {  # $1 = basedir.  g15m-wb: WHOLE BOX -- no numactl unless CPUS is set (repo ladder/srvlb.sh);
  # ulimit -n 65535 (box hard limit; srvlb.sh asks 200000) (1024 VU); buffer pool interleaved over all nodes by InnoDB's own
  # innodb_numa_interleave (built WITH_NUMA=ON), set ON here rather than in the shared cnf.
  ulimit -n 65535 2>/dev/null || ulimit -n "$(ulimit -Hn)"
  local pin=(); [ -n "$CPUS" ] && pin=(numactl --physcpubind=$CPUS --preferred=$MEMNODE)
  setsid nohup "${pin[@]}" \
      "$1/bin/mysqld" --defaults-file="$CNF" --basedir="$1" --innodb-numa-interleave=ON \
      >/dev/null 2>&1 </dev/null &
}

case "${1:-}" in
init)
  BASE=${2:?basedir}; stop_server
  log "wiping $DATADIR"
  rm -rf "$DATADIR"; mkdir -p "$DATADIR"
  numactl --physcpubind=$CPUS --preferred=$MEMNODE "$BASE/bin/mysqld" \
      --defaults-file="$CNF" --basedir="$BASE" --initialize-insecure >/dev/null 2>&1 || {
      log "initialize failed"; tail -20 "$DIR/mysqld-error.log"; exit 1; }
  log "initialized; starting pinned to set up the account"
  echo "$BASE" > "$DIR/.current-basedir"
  start_pinned "$BASE"
  sleep 5
  for _ in $(seq 1 150); do "$BASE/bin/mysqladmin" -S "$SOCK" -uroot ping 2>/dev/null | grep -q alive && break; sleep 2; done
  "$BASE/bin/mysql" -S "$SOCK" -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$PASS';
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH mysql_native_password BY '$PASS';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
  log "account ready"; "$BASE/bin/mysql" -S "$SOCK" -uroot -p"$PASS" -e "SELECT VERSION()" 2>/dev/null
  ;;
start)
  BASE=${2:?basedir}; stop_server
  echo "$BASE" > "$DIR/.current-basedir"
  : > "$DIR/mysqld-error.log"
  log "starting WHOLE-BOX cpus=${CPUS:-all} numa_interleave=ON: $BASE"
  start_pinned "$BASE"
  sleep 3; wait_ready "$BASE" 900 || exit 1
  PID=$(mypid)
  log "pid=$PID exe=$(readlink -f /proc/$PID/exe) md5=$(md5sum "$BASE/bin/mysqld" | cut -c1-12)"
  log "Cpus_allowed_list=$(awk '/Cpus_allowed_list/{print $2}' /proc/$PID/status)"
  grep -o 'bind:[0-9,-]*' /proc/$PID/numa_maps 2>/dev/null | sort -u | head -3 | tr '\n' ' '; echo
  echo "$PID" > "$DIR/.mysqld.pid"
  ;;
stop)   stop_server ;;
status)
  PID=$(mypid)
  if [ -n "$PID" ]; then
    echo "up pid=$PID exe=$(readlink -f /proc/$PID/exe)"
    echo "cpus=$(awk '/Cpus_allowed_list/{print $2}' /proc/$PID/status)"
    du -sh "$DATADIR" 2>/dev/null
  else echo "down"; fi
  ;;
*) echo "usage: srv-c.sh {init|start|stop|status} [basedir]"; exit 2 ;;
esac
