#!/bin/bash
# CLIENT driver of the MySQL 48xl perf capture: base vs pgoltob, 256 VU, 1536 WH, whole box (the HammerDB
# whole-box ladder config: srv-wb.sh unpinned + --innodb-numa-interleave=ON, datadir restored interleaved).
# Per arm, ONE server lifetime: restore-il -> start -> WARM-UP run (256 VU, 4 min rampup + 5 min) -> MEASURED run
# (256 VU, 4 min rampup + 5 min). The collectors (myperf-srv.sh slots) start the moment the measured run logs
# "Rampup complete". The warm-up run keeps first-touch faults of a cold buffer pool out of the profiles.
#   setsid nohup bash ~/g15m/myperf.sh > ~/g15m/myperf/run.out 2>&1 < /dev/null &
set -uo pipefail
source /home/ec2-user/g15m/env.sh
G=/home/ec2-user/g15m; B=$G/myperf; mkdir -p $B; SD=/home/ec2-user/myperf
ARMS=${ARMS:-"base pgoltob"}; VU=256; RU=4; DU=5
MY="/opt/mysql-gcc15-base/bin/mysql -S $SRV_SOCK -uroot -p$MYSQL_PASS -N -B"
ulimit -n $(ulimit -Hn); echo "client nofile=$(ulimit -n)"
drain() { local i n; for i in $(seq 1 60); do
    n=$(ssh_srv "$MY -e 'select count(*) from information_schema.processlist' 2>/dev/null" | tr -d '\r')
    [ -z "$n" ] && return 0; [ "$n" -le 20 ] && return 0; sleep 5; done; echo "  !!! still $n conns"; }
# point <outfile>: one HammerDB run in the background, timestamped lines -> $1 ; sets HP
point() { local TOUT=$(( (RU + DU + 3) * 60 )) TCL=/tmp/myperf-$(basename $1 .txt).tcl
  sed -e "s/@HOST@/$SRV_HOST/" -e "s/@RAMPUP@/$RU/" -e "s/@DURATION@/$DU/" -e "s/@TIMEOUT@/$TOUT/" -e "s/@VU@/$VU/" $G/point.tcl.in > $TCL
  ( cd $HAMMERDB && timeout $((TOUT + 300)) ./hammerdbcli auto $TCL 2>&1 < /dev/null ) \
    | awk '{print strftime("%Y-%m-%dT%H:%M:%SZ", systime(), 1), $0; fflush()}' > $1 & HP=$!; }
res() { grep -a 'System achieved' $1 | tr -d '\r' | sed 's/.*System achieved/System achieved/'; }
for arm in $ARMS; do
  P=/opt/mysql-gcc15-$arm; D=$SD/$arm
  [ -f $B/$arm.done ] && continue
  echo "=== $arm $(date -u +%FT%TZ)"
  ssh_srv "bash $SRV_DIR/srv-wb.sh stop" >/dev/null 2>&1
  ssh_srv "bash $SRV_DIR/um-dataset2.sh restore-il" 2>&1 | grep -E 'real|FAIL|restoring' | tr '\n' ' '; echo
  ssh_srv "touch ~/keepalive.stop; rm -rf $D; mkdir -p $D"
  ssh_srv "CPUS= bash $SRV_DIR/srv-wb.sh start $P" 2>&1 | tail -4 | tee $B/$arm.start
  grep -q 'md5=' $B/$arm.start || { echo "!!! START FAILED $arm"; exit 1; }
  ssh_srv "$MY -e 'select @@innodb_buffer_pool_size>>30, @@innodb_redo_log_capacity>>30, @@innodb_numa_interleave, (select count(*) from tpcc.warehouse)'" | sed 's/^/  pool_G,redo_G,numa_il,WH: /'
  ssh_srv "md5sum $P/bin/mysqld" | tee $B/$arm.md5
  point $B/$arm-warmup.txt; wait $HP; echo "  warm-up: $(res $B/$arm-warmup.txt)"; drain
  ssh_srv "pkill -f 'cpusample-al[l]'" || true
  ssh_srv "setsid nohup bash $SRV_DIR/cpusample-all.sh $D/cpu.txt >/dev/null 2>&1 < /dev/null &"
  point $B/$arm-measured.txt
  for i in $(seq 1 120); do grep -qa 'Rampup complete' $B/$arm-measured.txt && break; sleep 5; done
  grep -qa 'Rampup complete' $B/$arm-measured.txt || { echo "!!! no Rampup complete for $arm"; exit 1; }
  echo "  measured window start $(date -u +%T): collectors launched"
  ssh_srv "setsid nohup bash $SRV_DIR/myperf-srv.sh slots $D > $D/slots.out 2>&1 < /dev/null &"
  wait $HP; echo "  measured: $(res $B/$arm-measured.txt)"
  ssh_srv "cat $D/slots.log"; ssh_srv "pkill -f 'cpusample-al[l]'; true"
  ssh_srv "bash $SRV_DIR/srv-wb.sh stop" 2>&1 | tail -1
  grep -qa 'System achieved' $B/$arm-measured.txt && touch $B/$arm.done || { echo "!!! $arm measured run gave no result"; exit 1; }
done
echo "=== reports $(date -u +%FT%TZ)"
for arm in $ARMS; do TO=7200 ssh_srv "bash $SRV_DIR/myperf-srv.sh report $SD/$arm" | tail -1; done
ssh_srv "rm -f ~/keepalive.stop; setsid nohup bash ~/keepalive.sh >/dev/null 2>&1 < /dev/null &"
echo "MYPERF-DONE $(date -u +%FT%TZ)"
