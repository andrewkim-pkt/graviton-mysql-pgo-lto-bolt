#!/bin/bash
# GRAVITON (aarch64) variant of myperf-srv.sh. SERVER side of the MySQL perf capture
# (base vs pgolto, 256 VU, 1536 WH, whole box).
#
# WHAT CHANGED vs the Intel/AMD original, and why:
#   1. -M TopdownL1/L2 dropped: Intel-specific metric groups. (They did not print on the Intel
#      run either, so nothing is lost relative to the published ANALYSIS.md.)
#   2. The RAW EVENT LIST IS UNCHANGED. All 17 events probe OK on Neoverse V2 -- including
#      L1-icache/iTLB misses AND their denominators AND stalled-cycles-backend, which AMD
#      reported as <not supported>. This capture is therefore the most complete of the three legs.
#   3. perf record uses --call-graph fp, NOT lbr. Graviton has no LBR; `--call-graph lbr` fails.
#      Frame pointers give call graphs but not branch-accurate ones.
#   4. perf c2c is OMITTED -- it fails with "memory events not supported" in every form tried
#      (plain, -e arm_spe//, and arm_spe with load/store filters). This perf userspace has no
#      `perf mem` support for the arm_spe PMU. So there is NO HITM/cache-line data for Graviton.
#   5. ARM SPE op sampling replaces the Intel VTune hotspots slot (and AMD's ibs_op).
#   6. The compared arm is pgolto, not pgoltob: BOLT cannot run on this hardware.
set -uo pipefail

EVENTS="cycles,instructions,ref-cycles,branches,branch-misses,L1-icache-load-misses,iTLB-load-misses,dTLB-load-misses,LLC-loads,LLC-load-misses,context-switches,cpu-migrations,page-faults"
EVENTS2="stalled-cycles-frontend,stalled-cycles-backend,L1-icache-loads,iTLB-loads,branch-load-misses"

case ${1:-} in
slots)
  D=${2:?dir}; mkdir -p "$D"; T0=$(date +%s); echo "T0 $(date -u +%FT%TZ)" > "$D/T0"
  at() { local w=$(( T0 + $1 - $(date +%s) )); [ "$w" -gt 0 ] && sleep "$w"; echo "$(date -u +%T) $2"; }
  {
  at 15 "perf stat (main event list, identical to the x86 legs)"
  sudo perf stat -a -e "$EVENTS" -o "$D/perf-stat.txt" -- sleep 30

  at 60 "perf record --call-graph fp (no LBR on this part)"
  sudo perf record -a --call-graph fp -F 499 -o "$D/perf-record.data" -- sleep 30 > "$D/perf-record.log" 2>&1

  at 105 "ARM SPE op sampling (precise attribution; replaces VTune/IBS slot)"
  sudo perf record -a -e arm_spe// -o "$D/perf-spe.data" -- sleep 30 > "$D/perf-spe.log" 2>&1 \
     || echo "arm_spe record failed"

  at 150 "perf stat, front/back-end detail"
  sudo perf stat -a -e "$EVENTS2" -o "$D/perf-stat-frontend.txt" -- sleep 30

  at 195 "perf c2c -- SKIPPED, unavailable on this platform"
  echo "perf c2c is not available: 'memory events not supported' for plain, -e arm_spe//, and" >  "$D/c2c-UNAVAILABLE.txt"
  echo "arm_spe with load_filter/store_filter. This perf (6.1.190) has no perf-mem support for"  >> "$D/c2c-UNAVAILABLE.txt"
  echo "the arm_spe PMU, so there is no HITM / cache-line contention data for the Graviton leg." >> "$D/c2c-UNAVAILABLE.txt"

  echo "$(date -u +%T) collectors done"
  } > "$D/slots.log" 2>&1
  echo SLOTS-DONE ;;

report)
  D=${2:?dir}
  [ -f "$D/perf-record.data" ] && {
    sudo perf report -f -i "$D/perf-record.data" --no-children --sort comm,dso,sym --stdio -g none --percent-limit 0.1 > "$D/report-flat.txt" 2>/dev/null
    sudo perf report -f -i "$D/perf-record.data" --children --stdio -g caller,0.5,callee --percent-limit 1 > "$D/report-callgraph.txt" 2>/dev/null; }
  [ -f "$D/perf-spe.data" ] && sudo perf report -f -i "$D/perf-spe.data" --no-children --sort comm,dso,sym --stdio -g none --percent-limit 0.1 > "$D/report-spe.txt" 2>/dev/null
  echo REPORT-DONE ;;
*) echo "usage: $0 slots|report <dir>"; exit 2 ;;
esac
