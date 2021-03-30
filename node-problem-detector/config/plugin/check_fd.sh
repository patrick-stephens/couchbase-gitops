#!/bin/bash

# Based on: https://github.com/AliyunContainerService/node-problem-detector/blob/master/config/plugin/check_fd.sh
# check max fd open files

OK=0
NONOK=1

# Count number of fds allocated and ignore permission problems
count=$(find /host/proc -maxdepth 1 -type d -name '[0-9]*' -exec ls {}/fd \; 2>/dev/null|wc -l)
max=$(cat /host/proc/sys/fs/file-max)

if [[ $count -gt $((max*80/100)) ]]; then
   echo "current fd usage is $count and max is $max"
   exit $NONOK
fi
echo "node has no fd pressure"
exit $OK