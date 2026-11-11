#!/bin/bash
# llvm-bolt / perf2bolt 18.1.3 from source -> /opt/llvm-bolt-18.1.3 (the repo used LLVM 18.1.3 from Ubuntu).
set -uo pipefail
W=/home/ec2-user/g15m/src; mkdir -p $W; cd $W
[ -d llvm-18.1.3 ] || git clone -q --depth 1 -b llvmorg-18.1.3 https://github.com/llvm/llvm-project.git llvm-18.1.3 || exit 1
mkdir -p llvm-18.1.3/build && cd llvm-18.1.3/build
cmake -G Ninja ../llvm -DLLVM_ENABLE_PROJECTS=bolt -DLLVM_TARGETS_TO_BUILD=X86 -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_ASSERTIONS=OFF -DCMAKE_INSTALL_PREFIX=/opt/llvm-bolt-18.1.3 > $W/bolt-cmake.log 2>&1 || exit 1
ninja -j64 bolt > $W/bolt-build.log 2>&1 || { tail -30 $W/bolt-build.log; exit 1; }
sudo ninja install-llvm-bolt install-perf2bolt install-merge-fdata > $W/bolt-install.log 2>&1
/opt/llvm-bolt-18.1.3/bin/llvm-bolt --version | head -3
echo BOLT-BUILD-DONE
