#!/usr/bin/env perl
# discovery port for zabbix mysql monitor
use Data::Dumper;
my $data = "{\"data\":[";
open(PROCESS, "netstat -tunlp | grep mysqld |");
my @item = <PROCESS>;
my $i    = 0;
my $j    = 0;
my %h; 
foreach (@item) {
  chomp;
  my @F = split(/\s+/, $_);
  my($port) = ($F[3] =~ /(\d+$)/); 
  my($proc) = ($F[-1] =~ /(\d+)/);
  unless ($h{$proc} > 0 && $h{$proc} < $port) {
    $h{$proc} = $port;
    $i++;
  }
}

foreach my $port (values %h) {
  $j++;
  $data .= "\{\"{#MYSQLPORT}\":\"$port\"\}";
  $data .= $i == $j
         ? ']}'
         : ',';
}
print $data;
close(PROCESS);
