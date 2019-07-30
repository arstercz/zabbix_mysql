#!/bin/sh
# The wrapper for mymonitor script.
# It runs the script every 5 min. and parses the cache file on each following run.

PORT=$1
ITEM=$2
HOST='10.0.0.10'
DIR='/usr/local/zabbix_mysql'
CMD="/usr/bin/perl $DIR/bin/mymonitor.pl --host $HOST --port $PORT --items $ITEM"
CACHEFILE="/tmp/$HOST-mysql_stats.txt_$PORT"

if [ $ITEM == "max_duration" -o \
     $ITEM == "waiter_count" -o \
     $ITEM == "idle_blocker_duration" -o \
     $ITEM == "slave_check" ]; then
   /usr/bin/perl $DIR/bin/mymonitor.pl --host $HOST \
            --port $PORT --items $ITEM --nocache
   exit 0;
fi

if  [ -e $CACHEFILE ]; then
    # Check and run the script
    TIMEFLM=`stat -c %Y $CACHEFILE`
    TIMENOW=`date +%s`
    if [ `expr $TIMENOW - $TIMEFLM` -gt 300 ]; then
        rm -f $CACHEFILE
        $CMD 2>&1 > /dev/null
    fi
else
    $CMD 2>&1 > /dev/null
fi

# Parse cache file
if [ -e $CACHEFILE ]; then
    cat $CACHEFILE | sed 's/ /\n/g; s/-1/0/g'| \
          grep $ITEM | awk -F: '{print $2}'
else
    echo "ERROR: run the command manually to investigate the problem: $CMD"
fi
