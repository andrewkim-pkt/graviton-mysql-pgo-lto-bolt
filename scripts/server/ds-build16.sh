#!/bin/bash
# g15m: 512 WH golden (ladder/dsbuildlb.sh logic). CLIENT. Server init + start on the base arm, whole box for the load.
set -uo pipefail
source /home/ec2-user/g15m/env16.sh
LOG=$RESULTS/dsbuild16-$(date -u +%Y%m%d-%H%M%S).log; exec > >(tee -a "$LOG") 2>&1
BASE=/opt/mysql-gcc15-base
echo "=== 512 WH dataset build $(date -u +%FT%TZ)"
ssh_srv "cd $SRV_DIR && CPUS=0-63 bash srv-c.sh init $BASE" 2>&1 | tail -4
ssh_srv "cd $SRV_DIR && CPUS=0-63 bash srv-c.sh start $BASE" 2>&1 | tail -3
TCL=$WORK/schema-512.tcl
sed -e "s/@HOST@/$SRV_HOST/" -e "s/@WH@/$WAREHOUSES/" -e "s/@BUILDVU@/$BUILD_VU/" /home/ec2-user/g15m/schema.tcl.in > $TCL
echo "--- schema build start $(date -u +%T)"
time ( cd "$HAMMERDB" && ./hammerdbcli auto "$TCL" < /dev/null ) 2>&1 | grep -viE "^Vuser[0-9]+:(Loading|Elapsed|\.\.\.)" | tail -8
echo "--- row counts $(date -u +%T)"
ssh_srv "$BASE/bin/mysql -S $SRV_SOCK -uroot -p$MYSQL_PASS -N -B -e 'SELECT (SELECT COUNT(*) FROM tpcc.warehouse) w, (SELECT COUNT(*) FROM tpcc.district) d, (SELECT COUNT(*) FROM tpcc.order_line) ol, (SELECT COUNT(*) FROM tpcc.customer) c' 2>/dev/null"
ssh_srv "du -sh $SRV_DATADIR"
ssh_srv "cd $SRV_DIR && bash srv-c.sh stop" 2>&1 | tail -1
ssh_srv "cd $SRV_DIR && bash um-dataset2.sh golden" 2>&1 | grep -E 'real|golden|G'
echo "=== DSBUILD-DONE $(date -u +%FT%TZ)"
