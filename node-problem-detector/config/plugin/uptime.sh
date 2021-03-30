#!/bin/sh
OK=0
NONOK=1

seconds_acceptable=$1
seconds_up=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)

if [ "$seconds_up" -le "$seconds_acceptable" ]
then
    exit $OK
else
    exit $NONOK
fi