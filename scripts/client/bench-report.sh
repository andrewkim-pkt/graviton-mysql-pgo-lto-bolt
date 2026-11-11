#!/bin/bash
# g15m: per-point NOPM + busy% over the MEASURED window (HammerDB "Rampup complete" .. "System achieved"),
# node 1 (cpus 32-63,128-159) and whole box from the server sampler, client aggregate. Then the summary table.
B=${1:-/home/ec2-user/g15g/bench}
busy() { # file s e mode(node1|all|agg)
  awk -v s=$2 -v e=$3 -v m=$4 '
   function inset(c){ if(m=="all"||m=="agg") return c=="cpu"; n=substr(c,4)+0; return c!="cpu" && ((n>=32&&n<=63)||(n>=128&&n<=159)) }
   { t=$1; if(t<s||t>e) next; if(!inset($2)) next
     tot=$3+$4+$5+$6+$7+$8+$9+$10; idl=$6+$7
     if(!(t in T)){ T[t]=0; I[t]=0; ts[++k]=t }
     T[t]+=tot; I[t]+=idl }
   END{ if(k<2){print "-1";exit}; a=ts[1]; b=ts[k]; dt=T[b]-T[a]; di=I[b]-I[a]; printf "%.1f", 100*(dt-di)/dt }' $1; }
printf "%-12s %4s %10s %8s %8s %8s\n" tag VU NOPM node1% box% cli%
for f in $(ls $B/[0-9][0-9]-*-*.txt 2>/dev/null | sort); do
  base=$(basename $f .txt); vu=${base##*-}; tag=${base%-*}
  st=$(tr -d '\r' < $f | grep -a -m1 'Rampup complete' | awk '{print $1}')
  en=$(tr -d '\r' < $f | grep -a -m1 'System achieved' | awk '{print $1}')
  nopm=$(tr -d '\r' < $f | grep -a -m1 'System achieved' | grep -oE 'achieved [0-9]+' | awk '{print $2}')
  [ -n "$st" ] && [ -n "$en" ] || { printf "%-12s %4s %10s\n" $tag $vu FAILED; continue; }
  s=$(date -u -d "$st" +%s); e=$(date -u -d "$en" +%s)
  n1=$(busy $B/$tag.cpu $s $e node1); al=$(busy $B/$tag.cpu $s $e all); cl=$(busy $B/$tag.clicpu $s $e agg)
  printf "%-12s %4s %10s %8s %8s %8s\n" $tag $vu $nopm $n1 $al $cl
done | tee $B/points.txt
echo
awk '$1 ~ /^[0-9]/ && $3!="FAILED" { split($1,x,"-"); arm=x[2]; p=(x[1]+0<=7)?"A":"B"; k=arm","$2
      N[k]+=$3; C[k]++; U[k]+=$4; P[k","p]=$3 }
 END{ split("base afdo afdolto afdoltob pgo pgolto pgoltob",A," ")
  printf "| arm | 64vu nopm | vs base | 128vu nopm | vs base | mean gain | CPU/txn (64 / 128) |\n|---|---:|---:|---:|---:|---:|---:|\n"
  for(i=1;i<=7;i++){ a=A[i]; line="| " a
    g=0; ct=""
    for(j=1;j<=2;j++){ v=(j==1?64:128); k=a","v; kb="base,"v
      if(!C[k]||!C[kb]){ line=line " | - | -"; ct=ct (j==1?"":" / ") "-"; continue }
      n=N[k]/C[k]; nb=N[kb]/C[kb]; d=(n-nb)*100/nb; g+=d
      cpt=(U[k]/C[k])/n; cptb=(U[kb]/C[kb])/nb
      line=line sprintf(" | %\047d | %+.2f%%", n, d); ct=ct (j==1?"":" / ") sprintf("%+.1f%%",(cpt-cptb)*100/cptb) }
    print line sprintf(" | %+.2f%% | %s |", g/2, ct) } }' $B/points.txt
