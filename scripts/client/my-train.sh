#!/bin/bash
# g15m ADAPTATION of mysql-pgo-lto-bolt@1cebd37 scripts/my-train.sh: env path, gcc15 prefix, real golden restore
# before the run, srv-c.sh pins with --preferred=1 not --membind. 64 VU / 3 m rampup / 10 m measured, cell 32-63,128-159 as published.
# PGO training run for MySQL: drive the INSTRUMENTED /opt/mysql-gcc15-pgogen under TPROC-C
# so it writes the .gcda that -fprofile-use will consume. Runs on the CLIENT.
#
# WHY THE PROFILE DIRECTORY IS WIPED FIRST. The pgogen *build* already left 2065 .gcda / 22 MB
# in $PROFDIR: every build-time tool MySQL compiles and then runs (comp_err, gen_lex_hash,
# uca9dump, ...) is instrumented too, and it dumps counters when it exits. Those tools link the
# same mysys/strings objects mysqld does, at the same object paths, so their .gcda are the SAME
# FILES mysqld will merge into -- i.e. build-tool execution counts would be added to the
# workload's. The training profile is supposed to describe TPROC-C, not the build, so the
# directory is emptied and only the server run fills it. TUs that exist solely for the build
# tools then have no profile at all, which is exactly right and is what -Wno-missing-profile
# (set by fprofile.cmake) and -fprofile-partial-training exist to handle.
#
# WHY 64 vCPU / 64 VU.
#   * The cell is CPUS=32-63,128-159 MEMNODE=1 -- 64 vCPU on node 1. That is deliberately the
#     same cell as the PostgreSQL 16xl arms AND the cell the existing /opt/mysql-gcc14-boltonly
#     profile was taken in ("64 vCPU / 160 VU"), so the new stacked arm is comparable to both.
#   * But the VU count is 64, not that cell's 160-VU throughput peak, because the binary being
#     profiled is INSTRUMENTED and therefore several times slower. Per-arm profile siting is a
#     measured effect on this workload, not a detail: a saturated profile put 45% of its samples
#     in ut_delay and cost BOLT half its headroom (-2.5%). Holding VU at 160 against a binary
#     that is ~5x slower would queue far past saturation and train the optimiser on spin loops.
#     64 VU == the core count, which keeps the instrumented server near its own peak instead.
#
# The counters are only written when gcov's at-exit handler runs, so mysqld MUST come down
# cleanly. srv-c.sh stop does `mysqladmin shutdown`, waits up to 120 s, and escalates only to
# SIGTERM -- never SIGKILL, which would discard the whole training run.
set -uo pipefail
source ${ENVSH:-/home/ec2-user/g15g/env.sh}
DIR=/home/ec2-user/g15g

PREFIX=/opt/mysql-gcc15-pgogen
PROFDIR=/home/ec2-user/build-mypgo-profile-data
CPUS=96-159; MEMNODE=1; VCPU=64   # Graviton node-1 cell: 64 of node 1 s 96 cores, no SMT
# NB: env.sh already defines RAMPUP=2 and DURATION=5 for the matrix sweeps, so a plain
# ${RAMPUP:-3} here would silently inherit those instead of this script's own value. Use
# separate names (TRAIN_*) so the default is the documented one and an override still works.
VU=${TRAIN_VU:-64}
RAMPUP=${TRAIN_RAMPUP:-3}
DURATION=${TRAIN_DURATION:-10}
TIMEOUT=$(( (RAMPUP + DURATION + 6) * 60 ))

STAMP=$(date -u +%Y%m%d-%H%M%S)
LOG=$RESULTS/my-train-$STAMP.log
OUTF=$RESULTS/my-train-$STAMP.txt
exec > >(tee -a "$LOG") 2>&1

echo "=== my-train $(date -u +%FT%TZ)"
echo "    instrumented prefix : $PREFIX"
echo "    profile dir         : $PROFDIR"
echo "    cell                : $VCPU vCPU cpus=$CPUS preferred=$MEMNODE (srv-c.sh uses --preferred)"
echo "    load                : $VU VU, rampup ${RAMPUP}m, duration ${DURATION}m"

ssh_srv "test -x $PREFIX/bin/mysqld" || { echo "!!! no instrumented mysqld at $PREFIX"; exit 1; }

echo "--- stopping any mysqld, restoring the 1536 WH dataset"
ssh_srv "cd $SRV_DIR && bash srv-c.sh stop && bash um-dataset2.sh restore" 2>&1 | grep -E "real|restoring|FAIL"   # g15m: actually restore the golden
ssh_srv "cd $SRV_DIR && bash srv-c.sh stop" 2>&1 | tail -2
ssh_srv "test -d /mnt/ramdisk/mysqldata && du -sh /mnt/ramdisk/mysqldata" \
  || { echo "!!! no datadir -- run um-dataset2.sh restore on the server first"; exit 1; }

echo "--- emptying $PROFDIR (see header: build-tool counters are not training data)"
ssh_srv "find $PROFDIR -name '*.gcda' -delete 2>/dev/null; echo -n '    gcda now: '; find $PROFDIR -name '*.gcda' | wc -l"

echo "--- starting instrumented mysqld"
ssh_srv "cd $SRV_DIR && CPUS=$CPUS MEMNODE=$MEMNODE bash srv-c.sh start $PREFIX" 2>&1 | tail -6 \
  || { echo "!!! START FAILED"; exit 1; }

TCL=/tmp/my-train-$STAMP.tcl
sed -e "s/@RAMPUP@/$RAMPUP/" -e "s/@DURATION@/$DURATION/" -e "s/@TIMEOUT@/$TIMEOUT/" \
    -e "s/@VULIST@/$VU/" "$DIR/run-sweep-c.tcl.in" > "$TCL"

ssh_srv "setsid nohup bash $SRV_DIR/cpusample-all.sh $SRV_DIR/cpu-train-$STAMP.txt >/dev/null 2>&1 < /dev/null &"   # g15m: busy% evidence
echo "--- training load starting $(date -u +%FT%TZ)  (expect it to be SLOW: instrumented)"
( cd "$HAMMERDB" && ./hammerdbcli auto "$TCL" 2>&1 ) \
  | awk '{print strftime("%Y-%m-%dT%H:%M:%SZ"), $0; fflush()}' > "$OUTF"
grep -a 'System achieved' "$OUTF" | tr -d '\r' | sed 's/^/    /'

ssh_srv "pkill -f cpusample-al[l] ; true"
echo "--- clean shutdown (this is when the counters are written)"
ssh_srv "cd $SRV_DIR && bash srv-c.sh stop" 2>&1 | tail -3

echo "--- profile gates"
ssh_srv "echo -n '    .gcda files : '; find $PROFDIR -name '*.gcda' | wc -l; \
         echo -n '    profile size: '; du -sh $PROFDIR | cut -f1; \
         echo    '    largest counters:'; ls -S $PROFDIR/*.gcda 2>/dev/null | head -5 | sed 's|.*/|      |'"
N=$(ssh_srv "find $PROFDIR -name '*.gcda' | wc -l" | tr -d '\r ')
echo "=== my-train done $(date -u +%FT%TZ)  gcda=$N"
[ "${N:-0}" -gt 100 ] || { echo "!!! only ${N:-0} .gcda -- the training data did NOT land, do not build pgolto"; exit 1; }
echo "next: ssh the server and run  bash my-build.sh pgolto  then  bash my-build.sh pgoltoq"
