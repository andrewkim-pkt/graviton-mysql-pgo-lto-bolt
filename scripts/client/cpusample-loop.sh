#!/bin/bash
# 5 s CPU sampler. Pure bash builtins ($EPOCHSECONDS, read) apart from sleep, so it adds
# ~1 short-lived process per 5 s to a box where the measurement cares about 1% deltas.
OUT=${1:-/tmp/cpusample.txt}
: > "$OUT"
while :; do read -r line < /proc/stat; echo "$EPOCHSECONDS $line" >> "$OUT"; sleep 5; done
