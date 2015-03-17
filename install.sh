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

[[ ! -n $HOST ]] && {
   echo "no ip address."
   exit 1
}

HOST=$1


cp -a /usr/local/zabbix_mysql/templates/userparameter_discovery_mysql.conf $ZABBIX_DIR/
echo "1) # cp -a /usr/local/zabbix_mysql/templates/userparameter_discovery_mysql.conf $ZABBIX_DIR/"
echo
chmod +x /usr/local/zabbix_mysql/*.{sh,pl}
echo "2) # chmod +x /usr/local/zabbix_mysql/*.{sh,pl}"
echo
sed -i "s/10.0.0.10/$HOST/g" /usr/local/zabbix_mysql/get_mysql_stats_wrapper.sh
echo "3) # sed -i \"s/10.0.0.10/$HOST/g\" /usr/local/zabbix_mysql/get_mysql_stats_wrapper.sh"
echo
echo "install ok, restart zabbix_agent manually."
