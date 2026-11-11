#!/bin/bash
# SERVER side of the MySQL 48xl perf capture (base vs pgoltob, 256 VU, 1536 WH, whole box).
#   myperf-srv.sh slots <dir>    called by the client the moment HammerDB logs "Rampup complete" (= T0);
#                                runs the collectors one at a time, 30 s each, inside the 5 min measured window:
#                                T0+15 perf stat | T0+60 perf record | T0+105 perf c2c | T0+150 vtune hotspots | T0+195 vtune uarch
#   myperf-srv.sh report <dir>   perf/c2c/vtune reports, run only after every measured run is over
# Same collectors and options as the PostgreSQL 48xl capture (g15-perfcap-srv.sh).
set -uo pipefail
VT=/opt/intel/oneapi/vtune/2026.4/bin64/vtune
case ${1:-} in
slots)
  D=${2:?dir}; mkdir -p $D; T0=$(date +%s); echo "T0 $(date -u +%FT%TZ)" > $D/T0
  at() { local w=$(( T0 + $1 - $(date +%s) )); [ $w -gt 0 ] && sleep $w; echo "$(date -u +%T) $2"; }
  {
  at 15 "perf stat"
  sudo perf stat -a -M TopdownL1 -M TopdownL2 \
       -e cycles,instructions,ref-cycles,branches,branch-misses,L1-icache-load-misses,iTLB-load-misses,dTLB-load-misses,LLC-loads,LLC-load-misses,context-switches,cpu-migrations,page-faults \
       -o $D/perf-stat.txt -- sleep 30
  at 60 "perf record"
  sudo perf record -a --call-graph lbr -F 499 -o $D/perf-record.data -- sleep 30 > $D/perf-record.log 2>&1
  at 105 "perf c2c"
  sudo perf c2c record -a -o $D/perf-c2c.data -- sleep 30 > $D/perf-c2c.log 2>&1
  at 150 "vtune hotspots"
  sudo $VT -collect hotspots -knob sampling-mode=hw -knob enable-stack-collection=true -analyze-system \
       -finalization-mode=none -d 30 -r $D/vt-hotspots > $D/vt-hotspots.log 2>&1
  at 195 "vtune uarch-exploration"
  sudo $VT -collect uarch-exploration -analyze-system -finalization-mode=none -d 30 -r $D/vt-uarch > $D/vt-uarch.log 2>&1
  echo "$(date -u +%T) collectors done"
  } > $D/slots.log 2>&1
  echo SLOTS-DONE ;;
report)
  D=${2:?dir}
  sudo perf report -f -i $D/perf-record.data --no-children --sort comm,dso,sym --stdio -g none --percent-limit 0.1 > $D/report-flat.txt 2>/dev/null
  sudo perf report -f -i $D/perf-record.data --children --stdio -g caller,0.5,callee --percent-limit 1 > $D/report-callgraph.txt 2>/dev/null
  sudo perf c2c report -f -i $D/perf-c2c.data --stdio > $D/c2c-report.txt 2>/dev/null
  for v in vt-hotspots vt-uarch; do [ -d $D/$v ] || continue
    sudo $VT -finalize -r $D/$v > $D/$v.fin.log 2>&1
    sudo $VT -report summary -r $D/$v > $D/$v-summary.txt 2>&1
    sudo $VT -report hotspots -r $D/$v -format csv -csv-delimiter comma > $D/$v-hotspots.csv 2>&1; done
  sudo chown -R ec2-user: $D; echo "REPORT-DONE $D" ;;
*) grep -E '^#   ' "$0"; exit 1 ;;
esac
