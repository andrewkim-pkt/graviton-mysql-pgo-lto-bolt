#!/bin/bash
# g15m ADAPTATION (gcc 15.2.0) of mysql-pgo-lto-bolt@1cebd37 scripts/my-build.sh: compiler/ar/ranlib -> /opt/gcc15,
# prefixes -> /opt/mysql-gcc15-*, +rpath /opt/gcc15/lib64, new arms base/baseline-g/pgo, AutoFDO on the compile
# line for the LTO arms (AFDO_LINKONLY=1 = repo-exact), non-PGO arms in build-my-<arm>. Everything else verbatim.
# Build one MySQL 8.4.8 PGO arm. Runs ON the metal box (<metal-host>, AL2023, gcc14).
#
#   my-build.sh pgogen    instrumented, training only      -> /opt/mysql-gcc14-pgogen
#   my-build.sh pgolto    -fprofile-use + LTO  (arm L)     -> /opt/mysql-gcc14-pgolto
#   my-build.sh pgoltoq   pgolto + -g -Wl,-q (BOLT input)  -> /opt/mysql-gcc14-pgoltoq
#   AFDO=<file> my-build.sh afdo      -fauto-profile        (arm C)   -> /opt/mysql-gcc14-afdo2
#   AFDO=<file> my-build.sh afdolto   + LTO                 (arm CL)  -> /opt/mysql-gcc14-afdolto
#   AFDO=<file> my-build.sh afdoltoq  + LTO + -g -Wl,-q (BOLT input)  -> /opt/mysql-gcc14-afdoltoq
#     then, on the client: SRCPREFIX=/opt/mysql-gcc15-afdoltoq TAG=afdoltob bash my-bolt.sh
#                                                              (arm CLB) -> .../afdoltob
#
# THE AutoFDO CHAIN MIRRORS THE PGO CHAIN STAGE FOR STAGE -- afdo/afdolto/afdoltoq/afdoltob
# against pgogen/pgolto/pgoltoq/pgoltob -- deliberately, so C/CL/CLB vs (baseline)/L/LB is a
# comparison of PROFILE SOURCE (LBR hardware sampling vs instrumented counters) with the
# consumption stages held fixed. Keep the pairs aligned; any flag added to one side must be
# added to the other or the comparison quietly becomes a flag study.
#
# ARM C (afdo, no LTO) is the extra rung the PGO side does not have: it is also directly
# comparable to the BOLT-only arm, since both come from the same -O3 -g base and the same kind
# of LBR recording, so C-vs-B isolates "the compiler consumes the profile" against "a binary
# rewrite consumes it". C-vs-L instead confounds profile source with LTO; CL-vs-L is the pair
# to quote for that question.
#
# Prefixes are afdo2/afdolto/afdoltoq/afdoltob, NOT autofdo: /opt/mysql-gcc14-autofdo and
# -autofdo-bolt already exist from earlier campaigns and are the provenance for published
# numbers. Do not overwrite them.
#
# This is the PostgreSQL pgogen/pgolto/pgoltoq chain (pg-build.sh) ported to MySQL, and the
# arm names are deliberately the same so the two campaigns line up. The baseline arm A is the
# EXISTING /opt/mysql-gcc14-baseline -- it is not rebuilt here, because rebuilding the
# reference would invalidate every published delta measured against it.
#
# WHY THIS USES MySQL'S OWN cmake/fprofile.cmake INSTEAD OF HAND-ROLLED -fprofile-* FLAGS.
# Oracle ships a supported PGO path (FPROFILE_GENERATE / FPROFILE_USE) and it is materially
# better than what pg-build.sh had to do by hand:
#
#   * -fprofile-generate=${CMAKE_BINARY_DIR}-profile-data puts the .gcda in a SEPARATE
#     directory instead of next to the objects. PG's chain had to reuse one tree and was
#     forbidden from `make clean` (gcda live beside the .o and GCC keys them to the object's
#     absolute path). Here the tree is disposable -- but the .gcda filenames still encode the
#     mangled absolute object path, so THE BUILD DIRECTORY NAME MUST BE IDENTICAL across the
#     gen pass and every use pass. That is why all three arms build in $BLD and each one
#     `rm -rf`s it first. Change $BLD between passes and -fprofile-use silently finds nothing.
#   * -fprofile-update=prefer-atomic is set for us on the gen side. Non-negotiable here in a
#     way it was not for PG: mysqld is one process with hundreds of threads hammering the same
#     counters, where PG is a process per backend. Non-atomic counters would race and the
#     profile would be arithmetic noise.
#   * -fprofile-correction on the use side, likewise mandatory -- GCC hard-errors on the
#     inconsistent counts that concurrent merging leaves behind.
#   * WITH_LTO_DEFAULT is flipped ON by FPROFILE_USE, i.e. Oracle's own position is that PGO
#     and LTO belong together ("LTO combined with PGO boosts performance even more").
#
# FLAG DELTA VS THE PG ARMS, recorded so the two are never quoted as identical pipelines:
#   MySQL adds -fprofile-partial-training, which PG's pgolto did not have. Without it, every
#   function the training run never touched is optimised for SIZE, which on a codebase this
#   large silently pessimises anything the load did not cover. With it, untouched functions are
#   compiled as if there were no profile at all. Bigger binary, but the un-trained paths are
#   not sabotaged. Keeping Oracle's default here; the alternative is a build nobody supports.
#   PG used -flto=96 -ffat-lto-objects; MySQL drives -flto itself (see NPROC_EXECUTABLE below).
#
# TWO TRAPS IN MySQL'S LTO BLOCK, both handled below:
#
#   1) CMakeLists.txt:1687 does a bare FIND_PROGRAM(GCC_AR_EXECUTABLE gcc-ar) and then
#      SET(CMAKE_AR ${GCC_AR_EXECUTABLE}). On this box /usr/bin/gcc-ar is GCC *11* while the
#      compiler is /usr/bin/gcc14-gcc, so the archiver would load the wrong LTO plugin for the
#      IR in the .a files. FIND_PROGRAM is a no-op when the cache variable is already set, so
#      -DGCC_AR_EXECUTABLE=/opt/gcc15/bin/gcc-ar pins it. Same for gcc-ranlib.
#
#   2) CMakeLists.txt:1642-1657 sets -flto=$(nproc) for the link. nproc is 192 here, so the
#      LTRANS stage would fork 192 gcc processes. This box already has 618 GiB locked in 1 GiB
#      hugepages and ~349 GiB of tmpfs resident (the PG dataset), leaving ~540 GiB, and it has
#      hard-hung four times unprompted -- an OOM during a 20 minute link is not a risk worth
#      taking for link wall-clock. FIND_PROGRAM(NPROC_EXECUTABLE nproc) also honours a pre-set
#      cache variable, so we point it at a shim that prints $LTOJOBS.
set -uo pipefail

ARM=${1:?base|baseline-g|pgogen|pgo|pgolto|pgoltoq|afdo|afdolto|afdoltoq}
SRC=/home/ec2-user/mysql-8.4.8
BLD=/home/ec2-user/build-mypgo          # SAME name for every pass -- see header
PROFDIR=$BLD-profile-data               # == cmake's FPROFILE_DIR default
case "$ARM" in pgogen|pgo|pgolto|pgoltoq) ;; *) BLD=/home/ec2-user/build-my-$ARM ;; esac   # g15m: non-PGO arms get their own tree
DIR=/home/ec2-user/hwpgo
CC=/opt/gcc15/bin/gcc
CXX=/opt/gcc15/bin/g++
JOBS=${JOBS:-192}
LTOJOBS=${LTOJOBS:-48}

# Identical to build-arm-c.sh's baseline recipe. The ONLY differences between arms are the
# profile/LTO options appended per-case below; anything else would mean measuring the build
# options instead of the profile.
BASE_C="-O3 -march=native -mtune=native"
BASE_CXX="-O3 -march=native -mtune=native -std=gnu++20"

EXTRA_C=""; EXTRA_CXX=""; EXTRA_LD=""
declare -a CMAKE_EXTRA=()

case "$ARM" in
  base)          # g15m: the repo's baseline arm A, plain -O3 -march=native (WITH_LTO default OFF)
    PREFIX=/opt/mysql-gcc15-base
    ;;
  baseline-g)    # g15m: AutoFDO recording input (my-boltprof.sh TAG=baseline-g); -g does not change codegen
    PREFIX=/opt/mysql-gcc15-baseline-g
    EXTRA_C="-g"; EXTRA_CXX="-g"
    ;;
  pgo)           # g15m: NEW arm -- -fprofile-use without LTO, the PGO twin of arm afdo
    PREFIX=/opt/mysql-gcc15-pgo
    CMAKE_EXTRA=( -DFPROFILE_USE=1 -DWITH_LTO=OFF )
    ;;
  pgogen)
    PREFIX=/opt/mysql-gcc15-pgogen
    CMAKE_EXTRA=( -DFPROFILE_GENERATE=1 -DWITH_LTO=OFF )
    # No -g: this binary is never profiled with perf and never benchmarked, it only writes
    # .gcda. Debug info on a 2.4 GB mysqld costs build time for nothing.
    ;;
  pgolto)
    PREFIX=/opt/mysql-gcc15-pgolto
    # WITH_LTO passed explicitly rather than relying on fprofile.cmake's WITH_LTO_DEFAULT=ON,
    # which only takes effect if that file is included before the OPTION() at CMakeLists:981.
    CMAKE_EXTRA=( -DFPROFILE_USE=1 -DWITH_LTO=ON )
    ;;
  pgoltoq)
    PREFIX=/opt/mysql-gcc15-pgoltoq
    CMAKE_EXTRA=( -DFPROFILE_USE=1 -DWITH_LTO=ON )
    # The BOLT-able twin of pgolto, and NOT an arm itself. llvm-bolt rejects an input with no
    # .rela.text, which only -Wl,-q keeps, and perf2bolt binds a profile to the exact ELF it
    # was recorded against -- so the stacked arm has to be profiled on THIS binary, not on
    # /opt/mysql-gcc14-pgolto. Its own prefix, so the measured pgolto arm is never overwritten.
    # -Wl,-q retains relocations and does not change codegen, so the pair stays comparable.
    EXTRA_C="-g"; EXTRA_CXX="-g"; EXTRA_LD="-Wl,-q"
    ;;
  afdo)
    PREFIX=/opt/mysql-gcc15-afdo
    AFDO=${AFDO:?set AFDO=/path/to/mysql.afdo}
    [ -s "$AFDO" ] || { echo "!!! no profile at $AFDO"; exit 1; }
    # -g so the arm can be audited afterwards (GCC records its command line in .debug_str,
    # which is the only way to PROVE the profile was consumed) and so it can serve as a BOLT
    # input later. -g does not change codegen, so it does not make this arm incomparable.
    EXTRA_C="-fauto-profile=$AFDO -g"; EXTRA_CXX="-fauto-profile=$AFDO -g"
    CMAKE_EXTRA=( -DWITH_LTO=OFF )
    ;;
  # THE LTO ARMS PASS -fauto-profile AT LINK TIME, NOT COMPILE TIME, AND THIS IS FORCED ON US.
  # gcc 14.2.1 ICEs when -flto and -fauto-profile are given together on a compile:
  #     during GIMPLE pass: einline
  #     '                                    <- a diagnostic whose quoted name came out empty
  #     in pp_format, at pretty-print.cc:1753
  # Reproduced on a 4-line TU (#include <functional> + a std::function) with THREE different
  # .afdo files including PostgreSQL's, so it is a compiler bug, not a bad profile. Neither
  # -Wno-coverage-mismatch, -w, -fno-early-inlining, --param early-inlining-insns=0,
  # -flto-partition=none, -ffat-lto-objects, -fno-checking nor any -fdiagnostics-* form avoids it.
  # There is no gcc15 on this box, and switching compilers for one arm would destroy the
  # comparison with the gcc14 PGO arms anyway.
  #
  # Under LTO the optimisers -- including einline -- run again at LTRANS, i.e. during the link, so
  # handing the profile to the link is a legitimate place to consume it (and gives the profile a
  # cross-module view it does not have per-TU). It does not ICE. But "does not ICE" is not "was
  # consumed": the gate that settles it is the thread-main size table in my-afdo.sh, which must
  # show these arms shrinking log_writer et al the way the no-LTO arm C does. If the sizes come
  # back equal to a plain LTO build, the profile was ignored and these arms are mislabelled.
  afdolto)
    PREFIX=/opt/mysql-gcc15-afdolto
    AFDO=${AFDO:?set AFDO=/path/to/mysql.afdo}
    [ -s "$AFDO" ] || { echo "!!! no profile at $AFDO"; exit 1; }
    EXTRA_C="-fauto-profile=$AFDO -g"; EXTRA_CXX="-fauto-profile=$AFDO -g"   # g15m: compile line too (link-only is a no-op)
    [ "${AFDO_LINKONLY:-0}" = 1 ] && { EXTRA_C="-g"; EXTRA_CXX="-g"; }   # repo-exact fallback if gcc15 ICEs
    EXTRA_LD="-fauto-profile=$AFDO"
    CMAKE_EXTRA=( -DWITH_LTO=ON )
    ;;
  afdoltoq)
    PREFIX=/opt/mysql-gcc15-afdoltoq
    AFDO=${AFDO:?set AFDO=/path/to/mysql.afdo}
    [ -s "$AFDO" ] || { echo "!!! no profile at $AFDO"; exit 1; }
    # The BOLT-able twin of afdolto, and NOT an arm itself -- exactly the pgolto/pgoltoq split.
    # Same reasons: llvm-bolt rejects an input with no .rela.text (only -Wl,-q keeps it), and
    # perf2bolt binds a profile to the exact ELF it was recorded against, so the stacked arm has
    # to be profiled on THIS binary. Own prefix, so the measured afdolto arm is never overwritten.
    EXTRA_C="-fauto-profile=$AFDO -g"; EXTRA_CXX="-fauto-profile=$AFDO -g"   # g15m: compile line too
    [ "${AFDO_LINKONLY:-0}" = 1 ] && { EXTRA_C="-g"; EXTRA_CXX="-g"; }
    EXTRA_LD="-fauto-profile=$AFDO -Wl,-q"
    CMAKE_EXTRA=( -DWITH_LTO=ON )
    ;;
  *) echo "!!! unknown arm $ARM"; exit 1 ;;
esac

EXTRA_LD="$EXTRA_LD -Wl,-rpath,/opt/gcc15/lib64"   # g15m: gcc15 libstdc++ at runtime, link-only
echo "=== my-build $ARM $(date -u +%FT%TZ)"
echo "    prefix=$PREFIX"
echo "    bld=$BLD   profdir=$PROFDIR"
echo "    cmake extra: ${CMAKE_EXTRA[*]}"
echo "    extra C='$EXTRA_C' CXX='$EXTRA_CXX' LD='$EXTRA_LD'  jobs=$JOBS ltojobs=$LTOJOBS"
"$CC" --version | head -1

# Only the -fprofile-use arms consume .gcda. arm afdo consumes an .afdo instead (gated above),
# and pgogen produces them; asking for .gcda in either case fails a correct build.
if [ "$ARM" = pgo ] || [ "$ARM" = pgolto ] || [ "$ARM" = pgoltoq ]; then
  N=$(find "$PROFDIR" -name '*.gcda' 2>/dev/null | wc -l)
  echo "    .gcda in $PROFDIR: $N"
  [ "$N" -gt 100 ] || { echo "!!! only $N .gcda -- run 'my-build.sh pgogen', then a training load, then STOP mysqld CLEANLY (mysqladmin shutdown; a SIGKILL discards the counters)"; exit 1; }
fi

# nproc shim: caps the -flto=N the link stage inherits. See trap 2 in the header.
mkdir -p "$DIR"
NPROC_SHIM=$DIR/nproc-lto
printf '#!/bin/sh\necho %s\n' "$LTOJOBS" > "$NPROC_SHIM"; chmod +x "$NPROC_SHIM"

rm -rf "$BLD"; mkdir -p "$BLD"; cd "$BLD"

cmake "$SRC" \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$BASE_C $EXTRA_C" \
  -DCMAKE_CXX_FLAGS="$BASE_CXX $EXTRA_CXX" \
  -DCMAKE_EXE_LINKER_FLAGS="$EXTRA_LD" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DGCC_AR_EXECUTABLE=/opt/gcc15/bin/gcc-ar \
  -DGCC_RANLIB_EXECUTABLE=/opt/gcc15/bin/gcc-ranlib \
  -DNPROC_EXECUTABLE="$NPROC_SHIM" \
  -DWITH_BOOST="$SRC/extra/boost/boost_1_84_0" \
  -DWITH_SSL=system -DWITH_NUMA=ON \
  -DWITH_UNIT_TESTS=OFF -DWITH_ROUTER=OFF \
  -DFORCE_INSOURCE_BUILD=OFF \
  "${CMAKE_EXTRA[@]}" > "$DIR/cmake-$ARM.log" 2>&1
rc=$?
echo "--- cmake rc=$rc"
grep -E 'FPROFILE|profile-use|profile-generate|WITH_LTO|CMAKE_AR|Error' "$DIR/cmake-$ARM.log" | tail -12
[ $rc -eq 0 ] || { echo "!!! CMAKE FAILED"; tail -30 "$DIR/cmake-$ARM.log"; exit 1; }

# Prove the flags actually landed in the cache before spending 20 minutes on the build.
# Read GCC_AR_EXECUTABLE, not CMAKE_AR. MySQL does a plain SET(CMAKE_AR ${GCC_AR_EXECUTABLE}),
# which is a directory-scope variable, so CMakeCache.txt still shows CMake's own detected
# /usr/bin/ar and the gate looks failed on a build that is correctly wired. The cmake -- lines
# above (echoed by MySQL itself) are the authoritative view of the compile flags.
echo "--- flags as configured:"
grep -E '^GCC_(AR|RANLIB)_EXECUTABLE|^NPROC_EXECUTABLE|^CMAKE_(C|CXX)_FLAGS:' CMakeCache.txt \
  | sed 's/^/      /'

echo "=== cmake done $(date -u +%FT%TZ); building -j$JOBS"
BUILD_LOG=$DIR/build-$ARM.log
if ! time make -j"$JOBS" >"$BUILD_LOG" 2>&1; then
  echo "!!! BUILD FAILED; tail of $BUILD_LOG"; tail -60 "$BUILD_LOG"; exit 1
fi
echo "=== build done $(date -u +%FT%TZ); installing"
sudo make install >/dev/null 2>&1 || sudo make install 2>&1 | tail -10

BIN=$PREFIX/bin/mysqld
ls -l "$BIN" || { echo "!!! no mysqld at $BIN"; exit 1; }

echo "--- gates ---"
# readelf -SW truncates long section names, so grep -c '\.debug_line$' always returns 0 --
# match without the anchor or the gate can never pass.
echo "  .rela.text : $(readelf -SW "$BIN" | grep -cE '\.rela\.text')   (>=1 required for the pgoltoq BOLT input)"
echo "  .debug_line: $(readelf -SW "$BIN" | grep -c '\.debug_line')"
echo -n "  producer   : "
readelf -p .debug_str "$BIN" 2>/dev/null \
  | grep -m1 -oE 'GNU C\+\+[0-9]+ [^"]{0,3000}' | tr ' ' '\n' \
  | grep -E 'profile-use|profile-generate|profile-correction|partial-training|auto-profile|flto|march=|^-O3$|^-g$' \
  | sort -u | tr '\n' ' '; echo
echo -n "  auto-profile lines in build log: "; grep -c -- '-fauto-profile' "$BUILD_LOG"
echo -n "  profile-use lines in build log : "; grep -c -- '-fprofile-use' "$BUILD_LOG"
echo -n "  flto lines in build log        : "; grep -c -- '-flto' "$BUILD_LOG"
echo -n "  missing-profile warnings       : "; grep -c 'missing-profile\|profile count data file not found' "$BUILD_LOG"
echo -n "  coverage-mismatch errors       : "; grep -c 'corrupted profile info\|number of counters' "$BUILD_LOG"
"$BIN" --version
md5sum "$BIN"
echo "=== ARM $ARM COMPLETE $(date -u +%FT%TZ)"
