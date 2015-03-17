#!/usr/bin/env perl
# discovery port for zabbix mysql monitor
my $data = "{\"data\":[";
open(PROCESS, "netstat -natp|grep mysqld|awk -F: '{print \$2}'|awk '{print \$1}' |");
my @item = <PROCESS>;
my $i    = 0;
foreach(@item) {
    $i++;
    chomp;
    $data .= "\{\"{#MYSQLPORT}\":\"$_\"\}";
    $data .= $i == $#item + 1
           ? ']}'
           : ',';
    
}
print $data;
close(PROCESS);
