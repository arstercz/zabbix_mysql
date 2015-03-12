# zabbix_mysql
  Yet another mysql monitor for zabbix, like percona monitor for zabbix.

## read more:
   http://www.percona.com/doc/percona-monitoring-plugins/1.1/zabbix/index.html

## Note
   Instead of ss_get_mysql_stats.php with mymonitor.pl, the other configuration is similar with ss_get_mysql_stats.php.

   Read more: perldoc mymonitor.pl

## Require
  perl-DBI

  perl-DBD-mysql

## Test

\# perl  mymonitor.pl --host 172.30.0.2 --port 3300 --items hv

hv:36968

\# perl  mymonitor.pl --host 172.30.0.2 --port 3300 --items kx

kx:1070879944

xxxxxxxxxxxxxxxx

\# php ss_get_mysql_stats.php --host 172.30.0.2 --port 3300 --items hv

hv:36968

\# php ss_get_mysql_stats.php --host 172.30.0.2 --port 3300 --items kx

kx:1070911408
