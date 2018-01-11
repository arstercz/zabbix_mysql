#!/bin/bash

# zabbix mysql monitor initialization work.
# cz20150317

VERSION=cz20150317

set -e

[[ $UID -ne 0 ]] && {
   echo "must be root to initialize work."
   exit 1
}

ZABBIX_DIR="/etc/zabbix/zabbix_agentd.d"
[[ ! -e $ZABBIX_DIR ]] && {
   echo "/etc/zabbix/zabbix_agentd.d not exists."
   exit 1
}

interface=$1
[[ ! -n $interface ]] && {
   echo "no interface."
   exit 1
}

HOST=$(ip addr | perl -ne '
  if($p) { 
    if(/.+?inet\s+?
       ((?:\d{1,3}\.){3}\d+?)
       \/\d+?\s+brd/xsg) {
      print $1; $p = 0
    } 
  }; 
  $p++ if /em1/
')

cp -a /usr/local/zabbix_mysql/templates/userparameter_discovery_mysql.conf $ZABBIX_DIR/
echo "1) # cp -a /usr/local/zabbix_mysql/templates/userparameter_discovery_mysql.conf $ZABBIX_DIR/"
echo
chmod +x /usr/local/zabbix_mysql/bin/*.{sh,pl}
echo "2) # chmod +x /usr/local/zabbix_mysql/bin/*.{sh,pl}"
echo
sed -i "s/10.0.0.10/$HOST/g" /usr/local/zabbix_mysql/bin/get_mysql_stats_wrapper.sh
echo "3) # sed -i \"s/10.0.0.10/$HOST/g\" /usr/local/zabbix_mysql/bin/get_mysql_stats_wrapper.sh"
echo
chmod +s /bin/netstat
echo "4) # chmod +s /bin/netstat"
echo
echo "Following command executed:"
echo "# chmod +s /bin/netstat "
echo "to avoid the error:"
echo "(Not all processes could be identified, non-owned process info"
echo " will not be shown, you would have to be root to see it all.)"
echo
SEL=`sestatus | grep 'SELinux status' | awk  '{print $3}'`
if [ "$SEL" = "enabled" ]; then
    setenforce 0
    echo "5) # setenforce 0"
    echo
fi
echo "install ok, restart zabbix_agent service manually."
echo 
