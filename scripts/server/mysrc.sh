#!/bin/bash
set -uo pipefail
cd /home/ec2-user
[ -f mysql-8.4.8.tar.gz ] || wget -q -O mysql-8.4.8.tar.gz https://dev.mysql.com/get/Downloads/MySQL-8.4/mysql-8.4.8.tar.gz || exit 1
[ -d mysql-8.4.8 ] || tar xzf mysql-8.4.8.tar.gz
ls -d mysql-8.4.8/extra/boost/boost_1_84_0 && echo MYSRC-DONE
