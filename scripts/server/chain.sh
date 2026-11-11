#!/bin/bash
# g15m end-to-end chain (CLIENT, detached, resumable: each step leaves ~/g15m/chain/<step>.ok)
#   train -> afdo record + create_gcov -> 6 builds (pgo chain || afdo chain) -> 2 BOLT records + rewrites -> bench
set -uo pipefail
source /home/ec2-user/g15m/env.sh
G=/home/ec2-user/g15m; C=$G/chain; mkdir -p $C
ok() { [ -f $C/$1.ok ]; }
mark() { date -u +%FT%TZ > $C/$1.ok; echo "### step $1 OK $(date -u +%FT%TZ)"; }
die() { echo "!!! CHAIN STOP at $1: $2 $(date -u +%FT%TZ)"; exit 1; }
srvjob() { # name cmd : run detached on server, wait for its rc file
  local n=$1; shift
  ssh_srv "cd $SRV_DIR && rm -f logs/$n.rc && setsid nohup bash -c '$*; echo \$? > logs/$n.rc' > logs/$n.log 2>&1 < /dev/null &"
  until r=$(ssh_srv "cat $SRV_DIR/logs/$n.rc 2>/dev/null"); [ -n "$r" ]; do sleep 60; done
  echo "    server job $n rc=$r"; [ "$r" = 0 ]; }
until grep -q DSBUILD-DONE $G/results/ds-build.out 2>/dev/null; do sleep 60; done
ok golden || { ssh_srv "test -d /mnt/ramdisk/golden && du -sh /mnt/ramdisk/golden" || die golden "no golden"; mark golden; }

if ! ok train; then
  bash $G/my-train.sh || die train "my-train failed"
  mark train
fi
if ! ok afdorec; then
  PREFIX=/opt/mysql-gcc15-baseline-g TAG=baseline-g bash $G/my-boltprof.sh || die afdorec "recording failed"
  PD=$(ssh_srv "ls -t /home/ec2-user/g15m/prof/my-baseline-g-*.data | head -1")
  srvjob create_gcov "/home/ec2-user/g15m/src/autofdo/build-gcov/create_gcov --binary=/opt/mysql-gcc15-baseline-g/bin/mysqld --profile=$PD --gcov=/home/ec2-user/g15m/prof/mysql-g15.afdo --gcov_version=2; ls -l /home/ec2-user/g15m/prof/mysql-g15.afdo" || die afdorec create_gcov
  ssh_srv "test -s /home/ec2-user/g15m/prof/mysql-g15.afdo" || die afdorec "empty afdo"
  mark afdorec
fi
AF=/home/ec2-user/g15m/prof/mysql-g15.afdo
if ! ok builds; then
  # two independent chains: PGO arms share build-mypgo (sequential), AutoFDO arms each have their own tree
  ssh_srv "cd $SRV_DIR && rm -f logs/pgochain.rc logs/afdochain.rc; \
    setsid nohup bash -c 'r=0; for a in pgo pgolto pgoltoq; do [ -x /opt/mysql-gcc15-\$a/bin/mysqld ] && grep -q \"ARM \$a COMPLETE\" logs/build-\$a.log 2>/dev/null && continue; JOBS=96 bash my-build.sh \$a > logs/build-\$a.log 2>&1 || r=1; done; echo \$r > logs/pgochain.rc' >/dev/null 2>&1 < /dev/null & \
    setsid nohup bash -c 'r=0; for a in afdo afdolto afdoltoq; do [ -x /opt/mysql-gcc15-\$a/bin/mysqld ] && grep -q \"ARM \$a COMPLETE\" logs/build-\$a.log 2>/dev/null && continue; AFDO=$AF JOBS=96 bash my-build.sh \$a > logs/build-\$a.log 2>&1 || r=1; done; echo \$r > logs/afdochain.rc' >/dev/null 2>&1 < /dev/null &"
  until [ -n "$(ssh_srv 'cat ~/hwpgo/logs/pgochain.rc ~/hwpgo/logs/afdochain.rc 2>/dev/null | wc -l | grep -x 2')" ]; do sleep 120; done
  ssh_srv "cd $SRV_DIR; for a in pgo pgolto pgoltoq afdo afdolto afdoltoq; do echo \"\$a: \$(tail -1 logs/build-\$a.log)\"; done; grep -l 'internal compiler error' logs/build-*.log build-*.log 2>/dev/null"
  [ "$(ssh_srv 'cat ~/hwpgo/logs/pgochain.rc ~/hwpgo/logs/afdochain.rc' | tr -d '\n')" = 00 ] || die builds "a build failed (see server ~/hwpgo/logs/build-*.log)"
  mark builds
fi
for q in pgoltoq afdoltoq; do
  b=${q%q}b
  if ! ok rec-$q; then
    PREFIX=/opt/mysql-gcc15-$q TAG=$q bash $G/my-boltprof.sh || die rec-$q "recording failed"
    mark rec-$q
  fi
  if ! ok bolt-$b; then
    PD=$(ssh_srv "ls -t /home/ec2-user/g15m/prof/my-$q-*.data | head -1")
    srvjob bolt-$b "SRCPREFIX=/opt/mysql-gcc15-$q TAG=$b PDATA=$PD bash my-bolt.sh" || die bolt-$b "my-bolt failed"
    mark bolt-$b
  fi
done
ssh_srv "for a in base afdo afdolto afdoltob pgo pgolto pgoltob baseline-g pgogen pgoltoq afdoltoq; do printf '%-11s ' \$a; md5sum /opt/mysql-gcc15-\$a/bin/mysqld; done"
echo "CHAIN-BUILD-DONE $(date -u +%FT%TZ)"
ok bench || { bash $G/bench-cli.sh > $G/bench/bench.out 2>&1; grep -q BENCH-ALL-DONE $G/bench/bench.out && mark bench; }
bash $G/bench-report.sh
echo "CHAIN-ALL-DONE $(date -u +%FT%TZ)"
