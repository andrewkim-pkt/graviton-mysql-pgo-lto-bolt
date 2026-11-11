#!/bin/bash
# Build gcc 15.2.0 from source into /opt/gcc15 (ON THE SERVER). Bootstrap compiler: AL2023 gcc 11.5.
set -uo pipefail
W=/home/ec2-user/g15m/src; mkdir -p $W; cd $W
[ -f gcc-15.2.0.tar.xz ] || wget -q https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz || exit 1
[ -d gcc-15.2.0 ] || tar xf gcc-15.2.0.tar.xz
cd gcc-15.2.0 && ./contrib/download_prerequisites > ../gcc-prereq.log 2>&1 || exit 1
mkdir -p ../gcc-build && cd ../gcc-build
../gcc-15.2.0/configure --prefix=/opt/gcc15 --enable-languages=c,c++,lto --disable-multilib \
  --enable-lto --enable-plugin --with-system-zlib --disable-bootstrap-checks > ../gcc-configure.log 2>&1 || exit 1
make -j190 > ../gcc-make.log 2>&1 || { tail -40 ../gcc-make.log; exit 1; }
sudo make install > ../gcc-install.log 2>&1 || exit 1
/opt/gcc15/bin/gcc --version | head -1
echo GCC-BUILD-DONE
