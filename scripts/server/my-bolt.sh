#!/bin/bash
# g15m ADAPTATION of mysql-pgo-lto-bolt@1cebd37 scripts/my-bolt.sh: runs on the SERVER (llvm-bolt/perf2bolt 18.1.3 built from
# source into /opt/llvm-bolt-18.1.3; AL2023 has no BOLT), local cp instead of scp, gcc15 prefixes. Flags and gates verbatim.
# Stack BOLT on the MySQL PGO+LTO binary: /opt/mysql-gcc15-pgoltoq -> /opt/mysql-gcc14-pgoltob.
# Runs on the CLIENT, because AL2023 ships no BOLT in any repo -- llvm-bolt/perf2bolt exist only
# here (LLVM 18.1.3). The input ELF is fetched, rewritten locally, and pushed back.
#
# THE INPUT FILENAME MUST STAY `mysqld`. perf2bolt matches the recording to the ELF by file
# name, so a copy called mysqld-pgoltoq silently profiles nothing.
#
# Flag set is apply-bolt.sh's, verbatim, which is also pg-bolt4.sh's:
#   -reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions -split-all-cold
#   -split-eh -dyno-stats --update-debug-sections
# Deliberately NOT the rich set (--icf --icp=all --hugify): measured a wash-to-loss on this
# workload. Holding the flags identical to the existing BOLT-only arms is the point -- it makes
# pgoltob-vs-boltonly a comparison of what BOLT was stacked on, nothing else.
#
# Note this is the arm Andi Kleen warns about ("I wouldn't run bolt over already optimized
# binaries, it doesn't like it when the functions are already split"). GCC with a profile splits
# hot/cold, which is why the PG chain and this one build the BOLT input as its own arm; PG's
# pgoltoq did not add -fno-reorder-blocks-and-partition either, and the stacked PG arm still came
# out ahead of PGO+LTO alone by +0.73%. If the BOLT coverage gates below come out poor, that
# splitting interaction is the first thing to suspect.
set -uo pipefail
export PATH=/opt/llvm-bolt-18.1.3/bin:$PATH   # g15m: runs ON THE SERVER
WORK=/home/ec2-user/g15m/work; RESULTS=/home/ec2-user/g15m/results; mkdir -p $WORK $RESULTS

SRCPREFIX=${SRCPREFIX:-/opt/mysql-gcc15-pgoltoq}
TAG=${TAG:-pgoltob}
PDATA=${PDATA:?set PDATA to the perf recording from my-boltprof.sh}
# One fetch dir per source prefix. The file inside MUST stay named `mysqld` (perf2bolt matches
# the recording to the ELF by filename), so two sources cannot share a dir without one silently
# BOLTing the other's binary -- which is exactly the mix-up that produces a "stacked" arm that
# is really the old input rewritten with the new profile.
INDIR=$WORK/bolt-in-$(basename "$SRCPREFIX")
OUTDIR=$WORK/my-$TAG
FDATA=${FDATA:-$WORK/my-$TAG.fdata}
LOG=$RESULTS/my-$TAG-$(date -u +%Y%m%d-%H%M%S).log
mkdir -p "$INDIR" "$OUTDIR"
exec > >(tee -a "$LOG") 2>&1

FLAGS="-reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions -split-all-cold -split-eh -dyno-stats --update-debug-sections"

echo "=== my-bolt $TAG $(date -u +%FT%TZ)"
echo "    input  : $SRCPREFIX/bin/mysqld (on the server)"
echo "    profile: $PDATA"
ls -l "$PDATA" || exit 1

echo "--- fetching the input ELF (name stays 'mysqld')"
cp "$SRCPREFIX/bin/mysqld" "$INDIR/mysqld" || exit 1   # g15m: local copy, name stays mysqld
IN=$INDIR/mysqld
ls -l "$IN"

# --- gate the INPUT before spending anything. readelf -SW prints the section name mid-line
# followed by type/address columns, so grep -c '\.debug_line$' always returns 0 -- use -w or a
# perfectly good binary looks like a failure.
echo "--- input gates"
readelf -SW "$IN" | grep -cE '\.rela\.text' | sed 's/^/    rela.text sections : /'
readelf -SW "$IN" | grep -cw '\.debug_line'  | sed 's/^/    debug_line sections: /'
[ "$(readelf -SW "$IN" | grep -cE '\.rela\.text')" -ge 1 ] \
  || { echo "!!! no .rela.text -- llvm-bolt will reject this input (was -Wl,-q dropped?)"; exit 1; }
# Count the SECTION; do not test readelf's exit status. `readelf -p <name>` exits 0 even when the
# section is absent -- it only warns ("was not dumped because it does not exist") on stderr -- so
# `readelf -p .note.bolt_info X >/dev/null 2>&1 && fail` fires on EVERY binary, including a fresh
# GCC build. Verified: pgoltoq has 0 such sections and still tripped the old form of this gate.
[ "$(readelf -SW "$IN" | grep -c 'note.bolt_info')" -eq 0 ] \
  || { echo "!!! input already carries .note.bolt_info -- refusing to BOLT a BOLTed binary"; exit 1; }

echo "--- perf2bolt"
time perf2bolt -p "$PDATA" -o "$FDATA" "$IN" 2>&1 | tail -12
ls -l "$FDATA"
FSZ=$(stat -c%s "$FDATA" 2>/dev/null || echo 0)
echo "    .fdata = $FSZ B"
[ "$FSZ" -gt 500000 ] \
  || { echo "!!! .fdata is only $FSZ B -- a few hundred KB means the ELF/profile match FAILED"; exit 1; }

# Capture ALL llvm-bolt output: the coverage and dyno-stats gates print in the MIDDLE, and
# truncating them has already cost this project a re-run.
echo "--- llvm-bolt   flags: $FLAGS"
RAW=$OUTDIR/$TAG.bolt.log
time llvm-bolt "$IN" -o "$OUTDIR/mysqld" -data="$FDATA" $FLAGS > "$RAW" 2>&1
rc=$?
if [ $rc -ne 0 ] || [ ! -s "$OUTDIR/mysqld" ]; then
  echo "!!! llvm-bolt FAILED (rc=$rc)"; tail -40 "$RAW"; exit 1
fi
echo "    coverage / dyno-stats gates:"
grep -E 'functions out of|were relaid out|non-empty execution profile|taken branches|taken conditional|executed instructions|of the input binary|BOLT-WARNING: [0-9]' "$RAW" \
  | sed 's/^/      /' | head -25
ls -l "$OUTDIR/mysqld"

# Install into a clone of the pgoltoq tree: mysqld needs a matching share/ (errmsg.sys) and
# lib/plugin from the SAME build, so the clone base is the twin this binary came from, not
# some older prefix.
echo "--- install -> /opt/mysql-gcc15-$TAG"
cp "$OUTDIR/mysqld" /tmp/mysqld-$TAG
bash -c "sudo rm -rf /opt/mysql-gcc15-$TAG && sudo cp -a $SRCPREFIX /opt/mysql-gcc15-$TAG && \
         sudo cp /tmp/mysqld-$TAG /opt/mysql-gcc15-$TAG/bin/mysqld && \
         sudo chmod 755 /opt/mysql-gcc15-$TAG/bin/mysqld && rm -f /tmp/mysqld-$TAG && \
         ls -l /opt/mysql-gcc15-$TAG/bin/mysqld && \
         /opt/mysql-gcc15-$TAG/bin/mysqld --version && \
         echo -n '    bolt_info: ' && \
         readelf -p .note.bolt_info /opt/mysql-gcc15-$TAG/bin/mysqld | grep -oE 'llvm-bolt.*' | head -1 | cut -c1-200"
echo "=== my-bolt $TAG done $(date -u +%FT%TZ)"
