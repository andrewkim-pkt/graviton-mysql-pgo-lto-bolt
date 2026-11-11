#!/usr/bin/env bash
# Server side of the MySQL 48xl sysbench oltp_read_write ladder (4 gcc15 arms: base afdoltob pgolto pgoltob).
# Runs ON the MySQL 48xl; the client (sbm48.sh) calls these subcommands over ssh.
#   mount | init | snapshot     900G tmpfs | fresh sysbench datadir + root account + sbtest db | golden to RAM + EBS
#   start <arm> | stop          interleaved restore of the golden + whole-box start | clean shutdown
#   snap | stat                 /proc/stat jiffies | dirty pages, threads connected, history list length
# Config = the HammerDB whole-box one: my-c.cnf (200G pool, 64G redo) via my-sb.cnf, which changes only the
# datadir/pid-file and raises max_prepared_stmt_count (250 tables x threads x ~9 statements overflows 16382).
# mysqld is unpinned with --innodb-numa-interleave=ON and the datadir tmpfs pages are interleaved over all
# nodes, exactly as srv-wb.sh + um-dataset2.sh restore-il do for the HammerDB ladder.
set -uo pipefail
H=/home/ec2-user/hwpgo; CNF=$H/my-sb.cnf; SOCK=/tmp/mysql-sb.sock; PASS=mysql
TMPFS=/mnt/ramdisk; D=$TMPFS/sbdata; RG=$TMPFS/sbgolden; SNAP=/home/ec2-user/mysql-sb-snapshot-250x2400k
LOG=$H/mysqld-sb-error.log
die() { echo "FATAL: $*"; exit 1; }
mypid() { pgrep -f -- "defaults-file=$CNF" | head -1; }
armdir() { case $1 in base|afdoltob|pgolto|pgoltob) echo /opt/mysql-gcc15-$1;; *) die "arm $1";; esac; }
MY() { /opt/mysql-gcc15-base/bin/mysql -S $SOCK -uroot -p$PASS -N -B "$@" 2>/dev/null; }
conf() { sed -e "s|^datadir .*|datadir                         = $D|" \
             -e "s|^pid-file .*|pid-file                        = $TMPFS/mysqld-sb.pid|" \
             -e "s|^socket .*|socket                          = $SOCK|" \
             -e "s|^log-error .*|log-error                       = $LOG|" $H/my-c.cnf > $CNF
  echo "max_prepared_stmt_count         = 4194304" >> $CNF; }
startm() {  # $1 basedir
  ulimit -n 65535 2>/dev/null || ulimit -n "$(ulimit -Hn)"
  : > $LOG
  setsid nohup "$1/bin/mysqld" --defaults-file=$CNF --basedir=$1 --innodb-numa-interleave=ON >/dev/null 2>&1 </dev/null &
  for i in $(seq 1 450); do "$1/bin/mysqladmin" -S $SOCK -uroot -p$PASS ping 2>&1 | grep -qE "alive|Access denied" && return 0
    [ $i -gt 3 ] && [ -z "$(mypid)" ] && { tail -20 $LOG; die "mysqld exited"; }; sleep 2; done; die "start timeout"; }
stopm() { local p=$(mypid); [ -z "$p" ] && return 0
  /opt/mysql-gcc15-base/bin/mysqladmin -S $SOCK -uroot -p$PASS shutdown 2>/dev/null
  for _ in $(seq 1 300); do [ -z "$(mypid)" ] && return 0; sleep 1; done; kill "$(mypid)"; sleep 10; }
case ${1:-} in
mount)
  mountpoint -q $TMPFS || { sudo mkdir -p $TMPFS; sudo mount -t tmpfs -o size=900G tmpfs $TMPFS; sudo chown ec2-user: $TMPFS; }
  df -h $TMPFS | tail -1 ;;
init)
  [ -d $D ] && die "$D exists"; conf; mkdir -p $D
  /opt/mysql-gcc15-base/bin/mysqld --defaults-file=$CNF --basedir=/opt/mysql-gcc15-base --initialize-insecure >/dev/null 2>&1 \
    || { tail -20 $LOG; die initialize; }
  startm /opt/mysql-gcc15-base
  /opt/mysql-gcc15-base/bin/mysql -S $SOCK -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$PASS';
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH mysql_native_password BY '$PASS';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
CREATE DATABASE sbtest;
FLUSH PRIVILEGES;
SQL
  echo "init done $(MY -e 'select version()')" ;;
snapshot)
  [ -n "$(mypid)" ] || die "not running"
  echo "sbtest: $(MY -e "select round(sum(data_length+index_length)/1073741824,1) from information_schema.tables where table_schema='sbtest'") GiB"
  MY -e "set global innodb_fast_shutdown=0"; stopm
  rm -rf $RG $SNAP.partial; mkdir -p $RG
  numactl --interleave=all cp -a $D/. $RG/ || die "ram golden"
  cp -a $D $SNAP.partial && rm -rf $SNAP && mv $SNAP.partial $SNAP && sync && date -u +%FT%TZ > $SNAP/.snapshot-complete
  echo "golden: $(du -sh $RG | cut -f1) ram, $(du -sh $SNAP | cut -f1) ebs" ;;
start)
  B=$(armdir $2); [ -x $B/bin/mysqld ] || die "no $B"; stopm; conf
  SRC=$RG; [ -d $SRC ] || SRC=$SNAP; [ -d $SRC ] || die "no golden"
  rm -rf $D; mkdir -p $D; numactl --interleave=all cp -a $SRC/. $D/ || die restore; rm -f $D/.snapshot-complete
  startm $B; P=$(mypid)
  [ "$(readlink -f /proc/$P/exe)" = "$B/bin/mysqld" ] || { stopm; die "exe mismatch"; }
  echo "started $2 md5=$(md5sum < $B/bin/mysqld | cut -c1-12) aff=$(taskset -cp $P | awk '{print $NF}') $(MY -e 'select concat("pool=",@@innodb_buffer_pool_size>>30,"G redo=",@@innodb_redo_log_capacity>>30,"G numa_il=",@@innodb_numa_interleave," maxconn=",@@max_connections," stmts=",@@max_prepared_stmt_count)')"
  numastat -m | grep -E "^(Shmem|MemUsed) " ;;
stop) stopm; echo stopped ;;
snap) awk '$1=="cpu"{t=0;for(i=2;i<=NF;i++)t+=$i; print t, $5+$6}' /proc/stat ;;
stat) echo "$(MY -e "show global status where variable_name in ('Innodb_buffer_pool_pages_dirty','Threads_connected')" | awk '{printf "%s ", $2}')$(MY -e "select count from information_schema.innodb_metrics where name='trx_rseg_history_len'")" ;;
*) grep -E '^#   ' "$0"; exit 1 ;;
esac
