#!/bin/bash
# g15m WHOLE-BOX ladder driver (CLIENT). 8 mirrored passes: base afdoltob pgolto pgoltob | pgoltob pgolto afdoltob base.
# Per pass = ONE server lifetime: stop -> restore-il (numactl --interleave=all cp of the golden, tmpfs pages spread over
# all 3 nodes) -> start UNPINNED on all 192 vCPU (srv-wb.sh: no numactl, ulimit -n 65535, --innodb-numa-interleave=ON)
# -> VU 32 64 128 256 512 1024 ascending, one hammerdbcli per rung (point.tcl.in), rampup 2 / duration 3, drain between.
# Placement evidence per pass: numastat -m after restore and at end, numastat -p mysqld at end.
# CPU: server every cpuN line every 5 s, client aggregate every 5 s.
# RESUMABLE: a pass with $B/<tag>.done is skipped; a partial pass is re-run whole from its restore.
#   setsid nohup bash ~/g15m/bench-wb.sh > ~/g15m/wb/bench.out 2>&1 < /dev/null &
set -uo pipefail
source /home/ec2-user/g15g/env.sh
G=/home/ec2-user/g15g; B=$G/wb; mkdir -p $B
ARMS=${ARMS:-"base afdoltob pgolto pgoltob pgoltob pgolto afdoltob base"}
VUS=${VUS:-"32 64 128 256 512 1024"}; DU=$DURATION
# Rampup: the repo's own RAMPMODE=adaptive formula (ladder/matrixlb.sh rampup_for), because HammerDB logs VUs in at a
# measured 2.0 VU/s here (500 ms vuset delay; 1024 VU = 512 s), so the fixed 2 min left 256+ VU still logging in while
# measuring. ceil((VU/rate + settle)/60), floor RAMPUP -> 2 2 3 4 6 10 min for 32..1024 VU, every arm and pass alike.
CONNECT_RATE=${CONNECT_RATE:-2.0}; SETTLE=${SETTLE:-60}
rampup_for() { awk -v v="$1" -v r="$CONNECT_RATE" -v s="$SETTLE" -v m="$RAMPUP" 'BEGIN{ n=int((v/r+s+59)/60); print (n<m?m:n) }'; }
MY="/opt/mysql-gcc15-base/bin/mysql -S $SRV_SOCK -uroot -p$MYSQL_PASS -N -B"
ulimit -n 65536 2>/dev/null; echo "client ulimit -n = $(ulimit -n)  rampup(adaptive)=$(for v in $VUS; do echo -n "$v:$(rampup_for $v) "; done)duration=${DU}m"
exec 9>$B/.lock; flock -n 9 || { echo "another bench-wb is running"; exit 1; }
drain() { local i n; for i in $(seq 1 60); do
    n=$(ssh_srv "$MY -e 'select count(*) from information_schema.processlist' 2>/dev/null" | tr -d '\r')
    [ -z "$n" ] && return 0; [ "$n" -le 20 ] && return 0; sleep 5; done; echo "  !!! still $n conns"; }
i=0
for arm in $ARMS; do
  i=$((i+1)); tag=$(printf %02d $i)-$arm; P=/opt/mysql-gcc15-$arm
  [ -f $B/$tag.done ] && continue
  until ssh_srv true 2>/dev/null; do echo "[$(date -u +%T)] server unreachable, waiting"; sleep 120; done
  echo "=== $tag $P $(date -u +%FT%TZ)"
  ssh_srv "bash $SRV_DIR/srv-wb.sh stop" >/dev/null 2>&1
  ssh_srv "bash $SRV_DIR/um-dataset2.sh restore-il" 2>&1 | grep -E 'real|FAIL|restoring' | tr '\n' ' '; echo
  ssh_srv "numastat -m" > $B/$tag.numa-restore
  ssh_srv "CPUS= bash $SRV_DIR/srv-wb.sh start $P" 2>&1 | tail -4 > $B/$tag.start
  cat $B/$tag.start
  grep -q 'md5=' $B/$tag.start || { echo "!!! START FAILED $tag"; sleep 60; continue; }
  ssh_srv "$MY -e 'select @@innodb_buffer_pool_size/1073741824, @@innodb_redo_log_capacity/1073741824, @@max_connections, @@open_files_limit, @@innodb_numa_interleave' 2>/dev/null" \
    | sed 's/^/  pool,redo,maxconn,openfiles,numa_interleave: /' | tee $B/$tag.vars
  ssh_srv "pid=\$(cat $SRV_DIR/.mysqld.pid); md5sum $P/bin/mysqld; grep -E 'Cpus_allowed_list|Max open' /proc/\$pid/status /proc/\$pid/limits" > $B/$tag.ident
  ssh_srv "pkill -f 'cpusample-al[l]' ; true"
  ssh_srv "mkdir -p $SRV_DIR/wb; setsid nohup bash $SRV_DIR/cpusample-all.sh $SRV_DIR/wb/$tag.cpu >/dev/null 2>&1 < /dev/null &"
  pkill -f 'cpusample-loo[p]' ; setsid nohup bash $G/cpusample-loop.sh $B/$tag.clicpu >/dev/null 2>&1 < /dev/null &
  ok=1
  for vu in $VUS; do
    RU=$(rampup_for $vu); TOUT=$(( (RU + DU + 3) * 60 ))
    TCL=/tmp/g15m-wb-$tag-$vu.tcl
    sed -e "s/@HOST@/$SRV_HOST/" -e "s/@RAMPUP@/$RU/" -e "s/@DURATION@/$DU/" -e "s/@TIMEOUT@/$TOUT/" -e "s/@VU@/$vu/" $G/point.tcl.in > $TCL
    ( cd $HAMMERDB && timeout $((TOUT + 300)) ./hammerdbcli auto $TCL 2>&1 < /dev/null ) \
      | awk '{print strftime("%Y-%m-%dT%H:%M:%SZ", systime(), 1), $0; fflush()}' > $B/$tag-$vu.txt
    r=$(grep -a 'System achieved' $B/$tag-$vu.txt | tr -d '\r' | sed 's/.*System achieved/System achieved/')
    e=$(grep -acE 'Error|Too many connections|error connecting' $B/$tag-$vu.txt)
    nl=$(grep -ac "Processing 10000000" $B/$tag-$vu.txt); echo "  $tag $vu VU rampup=${RU}m logged_in=$nl: ${r:-NO RESULT}  (error lines: $e)"
    [ -n "$r" ] || ok=0
    case "$r" in *"achieved 0 NOPM"*) echo "  !!! $tag $vu VU achieved 0 NOPM -- not a result"; ok=0 ;; esac
    drain
  done
  ssh_srv "numastat -m" > $B/$tag.numa-end
  ssh_srv "numastat -p \$(cat $SRV_DIR/.mysqld.pid)" > $B/$tag.numa-proc
  ssh_srv "pkill -f 'cpusample-al[l]' ; true"; pkill -f 'cpusample-loo[p]'
  scp_from "$SRV_DIR/wb/$tag.cpu" "$B/$tag.cpu"
  ssh_srv "bash $SRV_DIR/srv-wb.sh stop" 2>&1 | tail -1
  [ $ok = 1 ] && touch $B/$tag.done || echo "!!! $tag incomplete, will retry"
done
echo "WB-ALL-DONE $(date -u +%FT%TZ)"
