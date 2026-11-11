#!/usr/bin/env bash
# CLIENT driver: MySQL sysbench oltp_read_write on the 24xl, 250 tables x 1.2M rows (~135 GB datadir incl. 64G redo, the size of the 768 WH
# HammerDB datadir), threads 32..1024. Arms: base afdoltob pgolto pgoltob (gcc15), 8 mirrored passes as in the
# HammerDB whole-box ladder. One server start (fresh interleaved golden restore) per pass, 120 s warm + 240 s measured.
# Runs detached ON the client; resumable (step 1 skipped once res/golden.ok exists, done rungs skipped).
set -uo pipefail
cd ~/sbm24; mkdir -p logs res
H=<PRIVATE_IP>; PER=256
S() { timeout ${TO:-1800} ssh -n -i ~/.ssh/<client_key> -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20 \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=4 ec2-user@$H "cd ~/hwpgo && $*"; }
say() { echo "=== [$(date -u +%T)] $*"; }
die() { say "!!! $*"; exit 1; }
csnap() { awk '$1=="cpu"{t=0;for(i=2;i<=NF;i++)t+=$i; print t, $5+$6}' /proc/stat; }
pct() { awk -v a=$1 -v b=$3 -v c=$2 -v d=$4 'BEGIN{printf "%.1f", 100*(1-(d-c)/(b-a))}'; }
ulimit -n $(ulimit -Hn)
SB="/opt/sysbench-mysql/bin/sysbench --db-driver=mysql --mysql-host=$H --mysql-port=3306 --mysql-user=root --mysql-password=mysql --mysql-db=sbtest --tables=250 --table-size=1200000 --rand-type=uniform"
# load <threads> <secs> <logprefix>: ceil(threads/PER) sysbench processes, threads split evenly
load() { LP=""; rm -f $3.p*.log; local np=$(( ($1 + PER - 1) / PER )); for k in $(seq 1 $np); do
  $SB --threads=$(( $1 / np )) --time=$2 --report-interval=10 oltp_read_write run > $3.p$k.log 2>&1 & LP="$LP $!"; done; }
ivtps() { for f in $1.p*.log; do awk -v w=$2 '/^\[ [0-9]+s \]/{t=$2; sub(/s/,"",t); if(t+0>w) for(i=1;i<=NF;i++) if($i=="tps:"){s+=$(i+1);n++}} END{print (n?s/n:0)}' $f; done | awk '{s+=$1}END{printf "%.1f", s}'; }
ivlat() { for f in $1.p*.log; do awk -v w=$2 '/^\[ [0-9]+s \]/{t=$2; sub(/s/,"",t); if(t+0>w) for(i=1;i<=NF;i++) if($i=="(ms,95%):"){s+=$(i+1);n++}} END{print (n?s/n:0)}' $f; done | awk '{s+=$1;n++}END{printf "%.2f", s/n}'; }
errs() { cat $1.p*.log | grep -iE 'FATAL|error' | grep -vc 'ignored errors' || true; }
ign() { cat $1.p*.log | awk '/ignored errors:/{s+=$3}END{print s+0}'; }

say "sbm24 start"
S "touch ~/keepalive.stop"
if [ ! -f res/golden.ok ]; then say "1 dataset 250 x 1.2M"
  S "./sbm24-srv.sh mount && ./sbm24-srv.sh init" || die init
  $SB --threads=125 oltp_read_write prepare > logs/prepare.log 2>&1 || die "prepare: $(tail -3 logs/prepare.log)"
  TO=7200 S "./sbm24-srv.sh snapshot" | tee res/golden.txt || die snapshot
  grep -q golden: res/golden.txt && touch res/golden.ok || die "snapshot failed"; fi
S 'for a in base afdoltob pgolto pgoltob; do echo "$a $(md5sum < /opt/mysql-gcc15-$a/bin/mysqld | cut -c1-12)"; done' | tee res/md5.txt
say "2 ladder: 8 mirrored passes, 32..1024 threads, 120 s warm + 240 s each"
P=1
for arm in base afdoltob pgolto pgoltob pgoltob pgolto afdoltob base; do
  pass=$(printf %02d $P)-$arm; P=$((P+1))
  grep -q "^$pass	1024	" res/bench.tsv 2>/dev/null && continue
  S "./sbm24-srv.sh start $arm" | tee -a logs/bench.log | tee logs/start-$pass.txt || die "start $arm"
  grep -q "^started" logs/start-$pass.txt || die "start $arm: $(tail -3 logs/start-$pass.txt)"
  for th in 32 64 128 256 512 1024; do
    grep -q "^$pass	$th	" res/bench.tsv 2>/dev/null && continue
    L=logs/b-$pass-$th; load $th 380 $L; sleep 120
    read T0 I0 < <(S "./sbm24-srv.sh snap"); read C0 J0 < <(csnap)
    sleep 240
    read T1 I1 < <(S "./sbm24-srv.sh snap"); read C1 J1 < <(csnap); ST=$(S './sbm24-srv.sh stat')
    wait $LP
    echo -e "$pass\t$th\t$(ivtps $L 120)\t$(pct $T0 $I0 $T1 $I1)\t$(pct $C0 $J0 $C1 $J1)\t$(ivlat $L 120)\t$(errs $L)\t$(ign $L)\t${ST// /,}" | tee -a res/bench.tsv
  done
  S "./sbm24-srv.sh stop" >/dev/null
done
# columns: pass threads tps server_busy% client_busy% p95_ms error_lines ignored_errors dirty_pages,threads_connected,history_len
say "3 summary"
awk -F'\t' '{arm=substr($1,4); k=arm" "$2; t[k]+=$3; b[k]+=$4; l[k]+=$6; n[k]++}
 END{split("afdoltob pgolto pgoltob",A," "); split("32 64 128 256 512 1024",T," ")
  printf "| threads | base tps | afdoltob | pgolto | pgoltob | busy base/afdo/pgolto/pgoltob | CPU/txn afdo / pgolto / pgoltob | p95 ms base / pgoltob |\n|---|---|---|---|---|---|---|---|\n"
  for(i=1;i<=6;i++){x=T[i]; B=t["base "x]/n["base "x]; bb=b["base "x]/n["base "x]; s=""; c=""; u=sprintf("%.1f",bb)
   for(j=1;j<=3;j++){a=A[j]; v=t[a" "x]/n[a" "x]; bv=b[a" "x]/n[a" "x]; g=100*v/B-100; m[j]+=g
     s=s sprintf(" %.0f (%+.2f%%) |",v,g); u=u sprintf("/%.1f",bv); c=c sprintf("%s%+.1f%%",(j>1?" / ":""),100*(bv/v)/(bb/B)-100)}
   printf "| %s | %.0f |%s %s | %s | %.1f / %.1f |\n",x,B,s,u,c,l["base "x]/n["base "x],l["pgoltob "x]/n["pgoltob "x]}
  printf "| mean | |"; for(j=1;j<=3;j++) printf " %+.2f%% |",m[j]/6; printf " | | |\n"}' res/bench.tsv | tee res/summary.md
S "rm -f ~/keepalive.stop; setsid nohup ~/keepalive.sh >/dev/null 2>&1 < /dev/null &"
say SBM24_DONE
