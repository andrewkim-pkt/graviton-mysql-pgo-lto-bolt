#!/bin/bash
# g15m ADAPTATION of mysql-pgo-lto-bolt@1cebd37 scripts/my-boltprof.sh: env path, gcc15 prefix, the perf.data stays on the
# server (llvm-bolt 18.1.3 was built there; AL2023 client has none), busy% sampler added. 160 VU, 120 s, um-collect.sh verbatim.
# Collect the BOLT profile for the stacked arm: drive /opt/mysql-gcc15-pgoltoq (the PGO+LTO
# binary built WITH -g -Wl,-q) under TPROC-C and perf-record it in steady state. Runs on the
# CLIENT; the perf recording itself happens on the server via um-collect.sh.
#
# The profile MUST come from pgoltoq and not from pgolto: perf2bolt binds a profile to the exact
# ELF it was recorded against, and pgolto has no .rela.text for llvm-bolt to work with anyway.
#
# Collection options are um-collect.sh verbatim -- `perf record -e cycles:u -j any,u -p PID`,
# no explicit period. That is the same collection that produced /opt/mysql-gcc14-boltonly and
# -boltsat, so LB-vs-B stays a comparison of what BOLT was stacked ON, not of how it was
# profiled.
#
# 160 VU here, NOT the 64 VU used for PGO training. This binary is optimised, so 160 VU is its
# measured throughput peak in this cell; and the peak is the right siting -- profiling the
# saturated point instead put 45% of samples in ut_delay and cost BOLT half its gain.
set -uo pipefail
source ${ENVSH:-/home/ec2-user/g15m/env.sh}
DIR=/home/ec2-user/g15m

# TAG only names the artifacts; PREFIX chooses what gets profiled. The same collection serves the
# AutoFDO arm too (TAG=baseline-g PREFIX=/opt/mysql-gcc14-baseline-g), because AutoFDO and BOLT
# take the SAME kind of recording -- `perf record -e cycles:u -j any,u` with LBR -- and differ only
# in the converter afterwards (create_gcov vs perf2bolt). What must NOT be shared is the profiled
# BINARY: each converter binds its output to the exact ELF it was recorded against.
PREFIX=${PREFIX:-/opt/mysql-gcc15-pgoltoq}
TAG=${TAG:-pgoltoq}
# CPU pinning only. MEMNODE is deliberately left UNSET: --membind is a hard constraint that
# forbids node fallback, and it OOM-killed this very script's 160 VU run 95 s in
# (oom-kill:constraint=CONSTRAINT_MEMORY_POLICY,nodemask=1) while 167 GB was free machine-wide.
# Linux default first-touch prefers the local node and spills, which is what a real instance does.
CPUS=32-63,128-159; VCPU=64
# NB: env.sh already defines RAMPUP=2 and DURATION=5 for the matrix sweeps, so a plain
# ${RAMPUP:-3} here would silently inherit those. Separate names, so the documented default
# holds: 160 VU attach at ~2/s (~80 s), which a 2 min rampup barely covers.
VU=${PROF_VU:-160}
RAMPUP=${PROF_RAMPUP:-3}
DURATION=${PROF_DURATION:-6}
PERFSECS=${PERFSECS:-120}
TIMEOUT=$(( (RAMPUP + DURATION + 5) * 60 ))

STAMP=$(date -u +%Y%m%d-%H%M%S)
LOG=$RESULTS/my-boltprof-$TAG-$STAMP.log
OUTF=$RESULTS/my-boltprof-$TAG-$STAMP.txt
PDATA_LOCAL=/home/ec2-user/g15m/prof/my-$TAG-$STAMP.data   # g15m: stays ON THE SERVER (BOLT runs there)
mkdir -p "$WORK"
exec > >(tee -a "$LOG") 2>&1

echo "=== my-boltprof $TAG $(date -u +%FT%TZ)"
echo "    profiling : $PREFIX"
echo "    cell      : $VCPU vCPU cpus=$CPUS mempolicy=default/first-touch, $VU VU"
echo "    window    : ${PERFSECS}s of cycles:u -j any,u, anchored on rampup completion"

ssh_srv "test -x $PREFIX/bin/mysqld" || { echo "!!! no mysqld at $PREFIX"; exit 1; }
echo -n "    input .rela.text on the server: "
ssh_srv "readelf -SW $PREFIX/bin/mysqld | grep -cE '\.rela\.text'"

echo "--- restoring dataset and starting $PREFIX"
ssh_srv "cd $SRV_DIR && bash srv-c.sh stop" >/dev/null 2>&1
ssh_srv "cd $SRV_DIR && bash um-dataset2.sh restore" 2>&1 | grep -E 'real|restoring|FAIL'
ssh_srv "cd $SRV_DIR && CPUS=$CPUS bash srv-c.sh start $PREFIX" 2>&1 | tail -5 \
  || { echo "!!! START FAILED"; exit 1; }

ssh_srv "setsid nohup bash $SRV_DIR/cpusample-all.sh $SRV_DIR/cpu-boltprof-$TAG-$STAMP.txt >/dev/null 2>&1 < /dev/null &"
TCL=/tmp/my-boltprof-$TAG-$STAMP.tcl
sed -e "s/@RAMPUP@/$RAMPUP/" -e "s/@DURATION@/$DURATION/" -e "s/@TIMEOUT@/$TIMEOUT/" \
    -e "s/@VULIST@/$VU/" "$DIR/run-sweep-c.tcl.in" > "$TCL"

( cd "$HAMMERDB" && ./hammerdbcli auto "$TCL" 2>&1 ) \
  | awk '{print strftime("%Y-%m-%dT%H:%M:%SZ"), $0; fflush()}' > "$OUTF" &
HDB=$!

# Anchor on the rampup marker, never a fixed offset: VUs attach at only ~2/s under load, so
# 160 VU take ~80 s and a fixed sleep would sample the ramp instead of steady state.
RAMPED=0
for i in $(seq 1 180); do
  grep -qa 'Rampup complete' "$OUTF" 2>/dev/null && { RAMPED=1; break; }
  kill -0 "$HDB" 2>/dev/null || break
  sleep 5
done
if [ "$RAMPED" = 1 ]; then
  sleep 20
  echo "--- [$(date -u +%T)Z] perf window ${PERFSECS}s"
  ssh_srv "mkdir -p /home/ec2-user/g15m/prof; cd $SRV_DIR && bash um-collect.sh $PDATA_LOCAL $PERFSECS" 2>&1 | tail -12
  :   # g15m: no fetch
else
  echo "!!! rampup marker never appeared -- no profile collected"
fi

wait "$HDB"
ssh_srv "pkill -f cpusample-al[l] ; true"
grep -a 'System achieved' "$OUTF" | tr -d '\r' | sed 's/^/    /'
ssh_srv "cd $SRV_DIR && bash srv-c.sh stop" >/dev/null 2>&1

ssh_srv "ls -lh $PDATA_LOCAL" || { echo "!!! no perf.data on server"; exit 1; }
echo "=== my-boltprof done $(date -u +%FT%TZ)"
echo "next: PDATA=$PDATA_LOCAL bash my-bolt.sh"
