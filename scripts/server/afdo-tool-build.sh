#!/bin/bash
# google/autofdo create_gcov (GCC flavour, -DENABLE_TOOL=GCOV). The repo records no create_gcov version.
set -uo pipefail
W=/home/ec2-user/g15m/src; mkdir -p $W; cd $W
[ -d autofdo ] || git clone -q --recursive https://github.com/google/autofdo.git autofdo || exit 1
cd autofdo; git log -1 --format='autofdo commit %H %cd'; git describe --tags 2>/dev/null
mkdir -p build-gcov && cd build-gcov
cmake -G Ninja -DBUILD_SHARED=TRUE -DENABLE_TOOL=GCOV -DCMAKE_BUILD_TYPE=Release ../ > $W/afdo-cmake.log 2>&1 || { tail -30 $W/afdo-cmake.log; exit 1; }
ninja -j32 create_gcov dump_gcov > $W/afdo-build.log 2>&1 || { tail -30 $W/afdo-build.log; exit 1; }
ls -l create_gcov dump_gcov; ./create_gcov --version 2>&1 | head -2
echo AFDO-TOOL-DONE
