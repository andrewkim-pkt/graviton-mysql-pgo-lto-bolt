#!/bin/bash
# 16xl MySQL whole-box chain (CLIENT): 512 WH golden, then the 8-pass mirrored ladder, then the report.
cd /home/ec2-user/g15m
bash ds-build16.sh || { echo DSBUILD-FAIL; exit 1; }
grep -q DSBUILD-DONE $(ls -t results/dsbuild16-*.log | head -1) || { echo DSBUILD-FAIL; exit 1; }
bash bench-wb16.sh > wb16/bench.out 2>&1
bash report-wb.sh /home/ec2-user/g15m/wb16 > wb16/report.md 2>&1
echo CHAIN16-DONE $(date -u +%FT%TZ)
