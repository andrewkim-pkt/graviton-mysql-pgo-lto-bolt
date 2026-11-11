# g15m-AMD client env (from env.sh.example). Client 172.31.44.102 (r7i.24xlarge) drives HammerDB;
# server 172.31.90.77 (r8a.metal-48xl, AMD EPYC 9R45, 2 NUMA nodes, 192 cores no SMT) builds + DUT.
# SRV_CPUS is the 64-vCPU node-1 cell: on Intel that was 32-63,128-159 (32 cores + SMT siblings),
# on AMD node 1 is CPUs 96-191 with no SMT, so 96-159 is 64 real cores. Not core-equivalent to the
# Intel cell -- see the campaign notes before comparing node-pinned NOPM across the two legs.
SRV_HOST=172.31.93.196
SRV_USER=ec2-user
SRV_KEY=/home/ec2-user/.ssh/id_g15amd
SRV_DIR=/home/ec2-user/hwpgo
SRV_CPUS=96-159
SRV_MEMNODE=1                    # used as numactl --preferred=1 (srv-c.sh), NOT --membind
SRV_PORT=3306
SRV_SOCK=/tmp/mysql.sock
SRV_DATADIR=/mnt/ramdisk/mysqldata
SRV_CNF=$SRV_DIR/my-c.cnf
HAMMERDB=/home/ec2-user/HammerDB-4.7
RESULTS=/home/ec2-user/g15g/results
WORK=/home/ec2-user/g15g/work
export LD_LIBRARY_PATH=/home/ec2-user/hdblib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}   # real libmysqlclient.so.21 for mysqltcl
WAREHOUSES=1536
BUILD_VU=64
RAMPUP=2
DURATION=3
MYSQL_USER=root
MYSQL_PASS=mysql
mkdir -p $RESULTS $WORK
ssh_srv() { ssh -n -i "$SRV_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
                -o ServerAliveInterval=15 -o ServerAliveCountMax=80 \
                "$SRV_USER@$SRV_HOST" "$@"; }
ssh_srv_in() { ssh -i "$SRV_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no "$SRV_USER@$SRV_HOST" "$@"; }
scp_to()  { scp -q -i "$SRV_KEY" -o StrictHostKeyChecking=no "$@" "$SRV_USER@$SRV_HOST:$SRV_DIR/"; }
scp_from() { scp -q -i "$SRV_KEY" -o StrictHostKeyChecking=no "$SRV_USER@$SRV_HOST:$1" "$2"; }
