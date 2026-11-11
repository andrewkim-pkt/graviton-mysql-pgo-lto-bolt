#!/bin/bash
# g15m: dataset handling (the repo's um-dataset2.sh is not published; this is ladder/dslb.sh's logic).
#   um-dataset2.sh golden    clean datadir -> RAM golden /mnt/ramdisk/golden (pages on node 2) + EBS snapshot
#   um-dataset2.sh restore   wipe datadir, restore from RAM golden (else EBS)
#   um-dataset2.sh mount     (after a reboot) mount the tmpfs and refill the RAM golden from EBS
# Deviation from dslb.sh: the restore cp runs under numactl --cpunodebind=1 --preferred=1, so the datadir's
#   um-dataset2.sh restore-il  same, but numactl --interleave=all cp (whole-box ladder; equal pages per node)
# tmpfs pages land on node 1 (mysqld's node) every time instead of wherever an unpinned cp happened to run.
set -uo pipefail
CNF=/home/ec2-user/hwpgo/my-c.cnf
TMPFS=/mnt/ramdisk; DATADIR=$TMPFS/mysqldata; RAMGOLD=$TMPFS/golden; SNAP=/home/ec2-user/mysql-snapshot-1536
running() { pgrep -f -- "defaults-file=$CNF" >/dev/null; }
case "${1:?golden|restore|restore-il|mount}" in
mount)
  mountpoint -q $TMPFS || { sudo mkdir -p $TMPFS; sudo mount -t tmpfs -o size=900G tmpfs $TMPFS; sudo chown ec2-user: $TMPFS; }
  df -h $TMPFS | tail -1
  if [ ! -d $RAMGOLD ] && [ -d $SNAP ]; then mkdir -p $RAMGOLD; time numactl --cpunodebind=0 --membind=0 cp -a $SNAP/. $RAMGOLD/; fi
  du -sh $RAMGOLD 2>/dev/null ;;
golden)
  running && { echo "FAIL: mysqld still running"; exit 1; }
  [ -d $RAMGOLD ] && { echo "FAIL: $RAMGOLD exists; refusing to overwrite a golden"; exit 1; }
  mkdir -p $RAMGOLD
  echo "[$(date -u +%T)] RAM golden <- $(du -sh $DATADIR | cut -f1)"
  time numactl --cpunodebind=0 --membind=0 cp -a $DATADIR/. $RAMGOLD/
  mkdir -p $SNAP; time cp -a $DATADIR/. $SNAP/; sync
  du -sh $RAMGOLD $SNAP ;;
restore)
  running && { echo "FAIL: mysqld still running"; exit 1; }
  SRC=""; [ -d $RAMGOLD ] && SRC=$RAMGOLD; [ -z "$SRC" ] && [ -d $SNAP ] && SRC=$SNAP
  [ -n "$SRC" ] || { echo "FAIL: no golden at $RAMGOLD or $SNAP"; exit 1; }
  rm -rf $DATADIR; mkdir -p $DATADIR
  echo "[$(date -u +%T)] restoring from $SRC"
  time numactl --cpunodebind=1 --preferred=1 cp -a $SRC/. $DATADIR/
  echo 1 | sudo tee /proc/sys/kernel/numa_balancing >/dev/null 2>&1 || true
  du -sh $DATADIR; df -h $TMPFS | tail -1 ;;
restore-il)   # g15m-wb: datadir tmpfs pages interleaved over ALL nodes (whole-box ladder), not node 1
  running && { echo "FAIL: mysqld still running"; exit 1; }
  SRC=""; [ -d $RAMGOLD ] && SRC=$RAMGOLD; [ -z "$SRC" ] && [ -d $SNAP ] && SRC=$SNAP
  [ -n "$SRC" ] || { echo "FAIL: no golden at $RAMGOLD or $SNAP"; exit 1; }
  rm -rf $DATADIR; mkdir -p $DATADIR
  echo "[$(date -u +%T)] restoring (interleave=all) from $SRC"
  time numactl --interleave=all cp -a $SRC/. $DATADIR/
  echo 1 | sudo tee /proc/sys/kernel/numa_balancing >/dev/null 2>&1 || true
  du -sh $DATADIR; df -h $TMPFS | tail -1 ;;
esac
