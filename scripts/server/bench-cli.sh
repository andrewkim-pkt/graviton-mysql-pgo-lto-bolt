#!/bin/bash
# g15m node-1 benchmark driver (CLIENT). Mirrored: pass A = base afdo afdolto afdoltob pgo pgolto pgoltob, pass B reversed.
# Per arm: stop -> restore golden -> start pinned node 1 (CPUs 32-63,128-159, --preferred=1) -> 64 VU point -> drain
# -> 128 VU point -> stop. One hammerdbcli per point (ladder/point.tcl.in), rampup 2 m / duration 3 m (repo ladder).
# CPU: server every cpuN line every 5 s (node-1 + whole box), client /proc/stat aggregate every 5 s.
# RESUMABLE: an arm with $B/<tag>.done is skipped; a partial arm is re-run from its restore.
#   setsid nohup bash ~/g15m/bench-cli.sh > ~/g15m/bench/bench.out 2>&1 < /dev/null &
set -uo pipefail
source /home/ec2-user/g15m/env.sh
G=/home/ec2-user/g15m; B=$G/bench; mkdir -p $B
ARMS="base afdo afdolto afdoltob pgo pgolto pgoltob pgoltob pgolto pgo afdoltob afdolto afdo base"
VUS="64 128"; RU=$RAMPUP; DU=$DURATION; TOUT=$(( (RU + DU + 3) * 60 ))
MY="/opt/mysql-gcc15-base/bin/mysql -S $SRV_SOCK -uroot -p$MYSQL_PASS -N -B"
ulimit -n 65536 2>/dev/null
exec 9>$B/.lock; flock -n 9 || { echo "another bench-cli is running"; exit 1; }
drain() { local i n; for i in $(seq 1 60); do
    n=$(ssh_srv "$MY -e 'select count(*) from information_schema.processlist' 2>/dev/null" | tr -d '\r')
    [ -z "$n" ] && return 0; [ "$n" -le 20 ] && return 0; sleep 5; done; echo "  !!! still $n conns"; }
i=0
for arm in $ARMS; do
  i=$((i+1)); tag=$(printf %02d $i)-$arm; P=/opt/mysql-gcc15-$arm
  [ -f $B/$tag.done ] && continue
  until ssh_srv true 2>/dev/null; do echo "[$(date -u +%T)] server unreachable, waiting"; sleep 120; done
  echo "=== $tag $P $(date -u +%FT%TZ)"
  ssh_srv "bash $SRV_DIR/srv-c.sh stop" >/dev/null 2>&1
  ssh_srv "bash $SRV_DIR/um-dataset2.sh restore" 2>&1 | grep -E 'real|FAIL|restoring' | tr '\n' ' '; echo
  ssh_srv "CPUS=$SRV_CPUS MEMNODE=$SRV_MEMNODE bash $SRV_DIR/srv-c.sh start $P" 2>&1 | tail -4 > $B/$tag.start
  cat $B/$tag.start
  grep -q 'md5=' $B/$tag.start || { echo "!!! START FAILED $tag"; sleep 60; continue; }
  ssh_srv "$MY -e 'select @@innodb_buffer_pool_size/1073741824, @@innodb_redo_log_capacity/1073741824, @@max_connections' 2>/dev/null" | sed 's/^/  pool,redo,maxconn: /'
  ssh_srv "md5sum $P/bin/mysqld; numastat -m | grep -E 'MemFree|MemUsed|Shmem '" > $B/$tag.numa-start
  ssh_srv "pkill -f 'cpusample-al[l]' ; true"
  ssh_srv "setsid nohup bash $SRV_DIR/cpusample-all.sh $SRV_DIR/bench/$tag.cpu >/dev/null 2>&1 < /dev/null &"
  pkill -f 'cpusample-loo[p]' ; setsid nohup bash $G/cpusample-loop.sh $B/$tag.clicpu >/dev/null 2>&1 < /dev/null &
  ok=1
  for vu in $VUS; do
    TCL=/tmp/g15m-point-$tag-$vu.tcl
    sed -e "s/@HOST@/$SRV_HOST/" -e "s/@RAMPUP@/$RU/" -e "s/@DURATION@/$DU/" -e "s/@TIMEOUT@/$TOUT/" -e "s/@VU@/$vu/" $G/point.tcl.in > $TCL
    ( cd $HAMMERDB && timeout $((TOUT + 300)) ./hammerdbcli auto $TCL 2>&1 < /dev/null ) \
      | awk '{print strftime("%Y-%m-%dT%H:%M:%SZ", systime(), 1), $0; fflush()}' > $B/$tag-$vu.txt
    r=$(grep -a 'System achieved' $B/$tag-$vu.txt | tr -d '\r' | sed 's/.*System achieved/System achieved/')
    echo "  $tag $vu VU: ${r:-NO RESULT}"
    [ -n "$r" ] || ok=0
    drain
  done
  ssh_srv "numastat -m | grep -E 'MemFree|MemUsed|Shmem '" > $B/$tag.numa-end
  ssh_srv "pkill -f 'cpusample-al[l]' ; true"; pkill -f 'cpusample-loo[p]'
  scp_from "$SRV_DIR/bench/$tag.cpu" "$B/$tag.cpu"
  ssh_srv "bash $SRV_DIR/srv-c.sh stop" 2>&1 | tail -1
  [ $ok = 1 ] && touch $B/$tag.done || echo "!!! $tag incomplete, will retry"
done
echo "BENCH-ALL-DONE $(date -u +%FT%TZ)"
