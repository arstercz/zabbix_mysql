#!/usr/bin/env perl
# discovery port for zabbix mysql monitor
my $data = "{\"data\":[";
open(PROCESS, "netstat -tunlp | grep mysqld |");
my @item = <PROCESS>;
my $i    = 0;
foreach(@item) {
    chomp;
    if(/:(\d+)\s/){
        $i++;
        $data .= "\{\"{#MYSQLPORT}\":\"$1\"\}";
        $data .= $i == $#item + 1
               ? ']}'
               : ',';
    }

}
print $data;
close(PROCESS);
