#!/bin/bash
# g15m: ladder/cpusample-loop.sh extended to every cpuN line (bash builtins only), so node-1 and
# whole-box busy% can both be computed for the measured window. Line format: "<epoch> cpuN user nice sys idle iowait irq softirq steal ..."
OUT=${1:-/tmp/cpusample.txt}
: > "$OUT"
while :; do
  t=$EPOCHSECONDS; { while read -r line; do [[ $line == cpu* ]] || break; echo "$t $line"; done < /proc/stat; } >> "$OUT"
  sleep 5
done
