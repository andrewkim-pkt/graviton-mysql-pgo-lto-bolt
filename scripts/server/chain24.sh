#!/bin/bash
# 24xl MySQL whole-box chain (CLIENT): 768 WH golden, then the 8-pass mirrored ladder, then the report.
cd /home/ec2-user/g15m
bash ds-build24.sh || { echo DSBUILD-FAIL; exit 1; }
grep -q DSBUILD-DONE $(ls -t results/dsbuild24-*.log | head -1) || { echo DSBUILD-FAIL; exit 1; }
bash bench-wb24.sh > wb24/bench.out 2>&1
bash report-wb.sh /home/ec2-user/g15m/wb24 > wb24/report.md 2>&1
echo CHAIN24-DONE $(date -u +%FT%TZ)
