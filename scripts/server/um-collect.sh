#!/bin/bash
# Record an LBR profile of the running mysqld, on the SERVER. Called by my-boltprof.sh over ssh.
#
#   bash um-collect.sh /tmp/my-pgoltoq.data 120
#
# NOTE ON PROVENANCE: this file is a RECONSTRUCTION. The original lives on the profiling host,
# which was unreachable when this repo was assembled; the option set below is the one recorded in
# my-boltprof.sh's header ("collection options are um-collect.sh verbatim -- perf record
# -e cycles:u -j any,u -p PID") and is consistent with the campaign's own gate output for the
# reference run: 19,741,114 SAMPLE events, 85 LOST (0.0%), 15.3 GB for a 120 s window, brstack
# non-empty in the first samples. Replace with the original before treating it as authoritative.
#
# -j any,u IS THE WHOLE POINT. Without branch stacks perf2bolt has nothing to build a CFG profile
# from. It is also the flag that fails on non-metal EC2 instances ("PMU Hardware or event type
# doesn't support branch stack sampling"), so probe the host before planning a campaign:
#   perf record -e cycles:u -j any,u -o /tmp/lbr-probe.data -- true
#
# The CALLER decides when to record. Recording must start after the workload reaches steady state
# -- my-boltprof.sh anchors this call on HammerDB's "Rampup complete" marker -- and the load level
# must be the binary's throughput PEAK, not saturation: a saturated profile put 45% of its samples
# in ut_delay and cost BOLT half its gain.
set -uo pipefail
OUT=${1:?usage: um-collect.sh <out.data> <seconds>}
SECS=${2:-120}

PID=$(pgrep -o -x mysqld) || { echo "FAIL: mysqld not running"; exit 1; }
echo "    recording pid=$PID for ${SECS}s -> $OUT"

rm -f "$OUT"
sudo perf record -e cycles:u -j any,u -p "$PID" -o "$OUT" -- sleep "$SECS"
sudo chown "$(id -un)":"$(id -gn)" "$OUT" 2>/dev/null
ls -lh "$OUT"

# --- gates. A perf.data that is mostly MMAP metadata is the classic silent failure: one earlier
# campaign on this fleet shipped a "+19.6%" build profiled with 27 samples in a 5.6 MB file.
echo "-- sample count gate:"
perf report -i "$OUT" --stats 2>/dev/null | grep -E 'LOST|SAMPLE events' | head -4

echo "-- LBR present gate (brstack in first samples):"
perf script -i "$OUT" -F brstack 2>/dev/null | head -4 | cut -c1-100
