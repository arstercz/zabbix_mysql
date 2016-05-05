#!/usr/bin/env perl
=pod

=head1 NAME

mymonitor.pl -- Yet another mysql monitor for zabbix, like percona monitor for zabbix.

=head1 SYNOPSIS

Usage: mymonitor [OPTION...]

=head1 RISKS

  Monitor user should be have super, process, slave privileges. password stored in plain

text, everyone can change the password method, such as Base64 ... 

=cut

package main;

use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;
use POSIX qw(mktime ctime strftime);
use List::Util qw(sum max);
use Getopt::Long;
use Math::BigInt;

my $host     = 'localhost';
my $port     = 3306;
my $user     = 'monitor';
my $password = 'monitor';
my @items;
my $ssl      = 0;
my $debug    = 0;
my $help     = 0;
my $charset  = 'utf8';
my $polltime = 300;
my $nocache  = 0;

# mysql ssl support
# http://dev.mysql.com/doc/refman/5.5/en/creating-ssl-certs.html
# http://www.percona.com/blog/2013/06/22/setting-up-mysql-ssl-and-secure-connections/
my $mysql_ssl_key  = '/etc/pki/mysql/client-key.pem';
my $mysql_ssl_cert = '/etc/pki/mysql/client-cert.pem';
my $mysql_ssl_ca   = '/etc/pki/mysql/ca.pem';

# general optoin
my $cache_dir = '/tmp';
my $timezone;
my %check_options = (
   'innodb'  => 1,
   'master'  => 1,
   'slave'   => 1,
   'procs'   => 1,
   'get_qrt' => 1,
);

# options for parameters.
GetOptions(
   "user|u=s"     => \$user,
   "host|H=s"     => \$host,
   "port|P=i"     => \$port,
   "password|p=s" => \$password,
   "items|i=s"    => \@items,
   "charset|c=s"  => \$charset,
   "ssl|s!"       => \$ssl,
   "debug|d!"     => \$debug,
   "poll=i"       => \$polltime,
   "nocache|d!"   => \$nocache,
   "help|h!"      => \$help,
) or die "error:$!";

if ( $help ) { 
    usage($0);
}

if ( -e '/home/mysql/.my.cnf' ) {
   ($user, $password) = read_cnf('/home/mysql/.my.cnf');
   debug("overwrite user and password options.")
}

if ( !$password ) {
    warn "Can not connect to MySQL without password.";
    usage($0);
    exit 1;
}

unless ( @items > 0 ) {
    warn "items can't be ignored, Comma-separated list of the items whose you want.";
    usage($0);
} else {
    @items     = split(/,|\ /,join(',',@items));
    my $result = get_mysql_stats();

    my @output;
    foreach my $item ( split(/ /, $result) ) {
        if ( grep { $_ eq  substr $item, 0, 2 } @items ) {
            push @output, $item;
        }
    }
    debug(@output);
    print join(" ", @output);
}

sub usage {
   my $name = shift;
   system("perldoc $name");
   exit 0;
}

sub read_cnf {
   my $cnf = shift;
   my @userinfo;
   open my $cf, '<', $cnf or warn "open file $cnf error: $!";
   debug("read cnf $cnf.");
   while(<$cf>) {
      next if not /^\s*(?:\[client\]|user|password)\s*/;
      push @userinfo, $1 if /\s*(?:user|password)\s*=(\S+)\s*/;
   }
   return @userinfo;
}

sub time_zone {
   my $time_t = mktime localtime;
   $ENV{TZ} = $timezone if defined $timezone;
   return strftime( "%Y-%m-%dT%H:%M:%S", localtime($time_t) );
}

sub debug {
   if( !$debug ) {
       return;
   }
   my $timeheader = time_zone();
   if( @_ + 0 > 1 ) {
      if( ref(\@_) eq 'ARRAY' ) {
          print $timeheader . ' [DEBUG] ' . join(" ", @_) . "\n";
      }
   } elsif ( @_ + 0 eq 1 ) {
      my $msg = shift @_;
      if( ref(\$msg) eq 'ARRAY' ) {
          print $timeheader . ' [DEBUG] ' . join(" ", @$msg) . "\n";
      } elsif ( ref(\$msg) eq 'HASH' ) {
          print $timeheader . ' [DEBUG] ' . join(" ", %$msg) . "\n";
      } elsif ( ref(\$msg) eq 'SCALAR' ) {
          print $timeheader . ' [DEBUG] ' . $msg . "\n";
      } else {
          return;
      }
   }
}

sub get_mysql_stats {
   my $sanitized_host = str_replace($host);
   my $cache_file     = "$cache_dir/$sanitized_host-mysql_stats.txt" . "_$port";
   debug("cache file is $cache_file");

   # first, check the cache.
   my $fp;
   if( -e $cache_dir && !$nocache ) {
       eval {
           open $fp, ">>", $cache_file;
       };
       if( $@ ) {
           undef $fp;
           debug("open file $cache_file: $@");
       } else {
           my $locked = flock($fp, 1); # LOCK_SH
           if( $locked ) {
               my ($f_size,$f_mtime) = (stat("$cache_file"))[7,9];
               open FH, '<', $cache_file;
               my @arr = <FH>;
               close FH;
               if( $f_size > 0 && $f_mtime + ($polltime/2) > time && @arr) {
                   debug("Using the cache file.");
                   close $fp;
                   return $arr[0];
               } else {
                   debug("The cache file seems too small or stale");
                   if( flock($fp, 2) ) {  # LOCK_EX
                       my ($f_size,$f_mtime) = (stat("$cache_file"))[7,9];
                       open FH, '<', $cache_file;
                       my @arr = <FH>;
                       close FH;
                       if ( $f_size > 0 && $f_mtime + ($polltime/2) > time && @arr ) {
                           debug("Using the cache file.");
                           close $fp;
                           return $arr[0];
                       }
                       truncate $fp,0;
                   }
                }
             } else {
                 undef $fp;
                 debug("Couldn't lock the cache file, ignoring it.");
             }
       }
   } else {
       debug("Caching is disabled.");
   }

   # connect to MySQL
   debug("connect to $host, $port, $user, xxxxxxxx ...");
   my $dbpre = MySQL::dbh->new(
       host => $host,
       port => $port,
       user => $user,
       password => $password,
       charset  => $charset,
       driver   => 'mysql',
   );

   my $dbh;
   if( $ssl ) {
       $dbh = $dbpre->get_dbh('information_schema',{AutoCommit => 1, mysql_ssl => 1, mysql_ssl_client_key => '/etc/pki/mysql/client-key.pem', mysql_ssl_client_cert => '/etc/pki/mysql/client-cert.pem', mysql_ssl_ca_file => '/etc/pki/mysql/ca.pem'});
   } else {
       $dbh = $dbpre->get_dbh('information_schema',{AutoCommit => 1});
   }

   # set up variables.
   # Holds the result of SHOW STATUS, SHOW INNODB STATUS, etc
   my %status = (
       'relay_log_space'          => undef,
       'binary_log_space'         => undef,
       'current_transactions'     => 0,
       'locked_transactions'      => 0,
       'active_transactions'      => 0,
       'innodb_locked_tables'     => 0,
       'innodb_tables_in_use'     => 0,
       'innodb_lock_structs'      => 0,
       'innodb_lock_wait_secs'    => 0,
       'innodb_sem_waits'         => 0,
       'innodb_sem_wait_time_ms'  => 0,
       # Values for the 'state' column from SHOW PROCESSLIST (converted to
       # lowercase, with spaces replaced by underscores)
       'State_closing_tables'       => 0,
       'State_copying_to_tmp_table' => 0,
       'State_end'                  => 0,
       'State_freeing_items'        => 0,
       'State_init'                 => 0,
       'State_locked'               => 0,
       'State_login'                => 0,
       'State_preparing'            => 0,
       'State_reading_from_net'     => 0,
       'State_sending_data'         => 0,
       'State_sorting_result'       => 0,
       'State_statistics'           => 0,
       'State_updating'             => 0,
       'State_writing_to_net'       => 0,
       'State_none'                 => 0,
       'State_other'                => 0, # Everything not listed above
   );

   # Get SHOW STATUS and convert the name-value array to status hash
   my $result = $dbh->selectall_arrayref("SHOW /*!50002 GLOBAL */ STATUS");
   foreach my $info (@$result) {
       my($var, $val) = @$info;
       $status{$var} = $val;
   }

   # Get SHOW VARIABLES and do the same thing, adding it to the status hash
   $result = $dbh->selectall_arrayref("SHOW VARIABLES");
   foreach my $info (@$result) {
       my($var, $val) = @$info;
       $status{$var} = $val;
   }

   # Get SHOW SLAVE STATUS, and add it to %status array.
   if( $check_options{'slave'} ) {
       $result = $dbh->selectrow_hashref("SHOW SLAVE STATUS");
       my $slave_status_rows_gotten = 0;

       # Must lowercase keys because different MySQL versions have different lettercase.
       # $hash{lc $_} = delete $hash{$_} for keys %hash;
       # %hash = map{ lc $_ => $hash{$_} } keys %hash;
       $result->{lc $_} = delete $result->{$_} for keys %$result;

       foreach my $info (keys %$result) {
           $slave_status_rows_gotten++;
           last if $slave_status_rows_gotten == 0;
           $status{'relay_log_space'} = $result->{'relay_log_space'};
           $status{'slave_lag'}       = $result->{'seconds_behind_master'};
           
           # Scale slave_running and slave_stopped relative to the slave lag.
           $status{'slave_running'} = $result->{'slave_sql_running'} eq 'Yes'
                                    ? $status{'slave_lag'}
                                    : 0;
           $status{'slave_stopped'} = $result->{'slave_sql_running'} eq 'Yes'
                                    ? 0
                                    : $status{'slave_lag'};
           $status{'running_slave'} = $result->{'slave_sql_running'} eq 'Yes' && $result->{'slave_io_running'} eq 'Yes'
                                    ? 1
                                    : 0;
       }
       if( $slave_status_rows_gotten == 0 ) {
           debug("Got nothing from SHOW SLAVE STATUS.");
           $status{'running_slave'} = 1;
       }
   }

   # Get SHOW MASTER STATUS, and add it to the $status hash.
   if( $check_options{'master'} && exists $status{'log_bin'}
       && $status{'log_bin'} eq 'ON'
      ) {
       my @binlogs;
       $result = $dbh->selectall_arrayref("SHOW MASTER LOGS");
       foreach my $info (@$result) {
          my($b_name, $b_size) = @$info;
          push @binlogs, $b_size;
       }

       if( @binlogs + 0 > 0 ) {
           $status{'binary_log_space'} = tonum(sum @binlogs);
       }
   }

   # Get SHOW PROCESSLIST and aggregate it by state, and add it to the $status hash.
   if( $check_options{'procs'} ) {
       $result = $dbh->selectall_hashref("SHOW PROCESSLIST",'Id');
       foreach my $info (keys %$result) {
           my $state = $result->{$info}->{'State'} || 'NULL';
           if ( $state eq '' ) {
               $state = 'none';
           }

           # MySQL 5.5 replaces the 'Locked' state with a variety of "Waiting for
           # X lock" types of statuses.  Wrap these all back into "Locked" because
           # we don't really care about the type of locking it is.
           $state =~ s/^(Table lock|Waiting for .*lock)$/Locked/gi;
           $state = lc $state;
           my $key = "State_" . $state;
           if(exists $status{$key}) {
               $status{$key} += 1;
           } else {
               $status{'State_other'} += 1;
           }
       }
   }

   # Get SHOW ENGINES to be able to determine whether InnoDB is present.
   my %engines;
   $result = $dbh->selectall_hashref("SHOW ENGINES", 'Engine');
   foreach my $info (keys %$result) {
      $engines{$info} = $result->{$info}->{'Support'};
   }

   # Get SHOW INNODB STATUS and extract the desired metrics from it, then add
   # those to the status hash.
   if( $check_options{'innodb'} && exists $engines{'InnoDB'} && 
       $engines{'InnoDB'} eq 'YES' || $engines{'InnoDB'} eq 'DEFAULT'
     ) {
       $result          = $dbh->selectrow_hashref("SHOW /*!50000 ENGINE*/ INNODB STATUS");
       my $istatus_text = $result->{'Status'};
       my $istatus_vals = get_innodb_status($istatus_text);

       # Get response time histogram from Percona Server or MariaDB if enabled.
       if( $check_options{'get_qrt'} && exists $status{'have_response_time_distribution'}
           && $status{'have_response_time_distribution'} eq 'YES' 
           || exists $status{'query_response_time_stats'}
           && $status{'query_response_time_stats'} eq 'ON' ) {
           debug("Getting query time histogram.");
           my $i = 0;
           my $sql_response = "SELECT `count`, ROUND(total * 1000000) AS total " 
                            . "FROM INFORMATION_SCHEMA.QUERY_RESPONSE_TIME "
                            . "WHERE `time` <> 'TOO LONG'";
           $result = $dbh->selectall_arrayref("$sql_response");
           foreach my $row (@$result) {
               last if $i > 13;
               my ($total, $count) = @$row;
               my $count_key = sprintf("Query_time_count_%02d", $i);
               my $total_key = sprintf("Query_time_count_%02d", $i);
               $status{$count_key} = $count;
               $status{$total_key} = $total;
               $i++;
           }
           # It's also possible that the number of rows returned is too few.
           # Don't leave any status counters unassigned; it will break graphs.
           while ( $i < 13 ) {
               my $count_key = sprintf("Query_time_count_%02d", $i);
               my $total_key = sprintf("Query_time_count_%02d", $i);
               $status{$count_key} = 0;
               $status{$total_key} = 0;
           }
       } else {
           debug("Not getting time histogram because it is not enabled.");
       }

        # Override values from InnoDB parsing with values from SHOW STATUS,
        # because InnoDB status might not have everything and the SHOW STATUS is
        # to be preferred where possible.
        my %overrides = (
            'Innodb_buffer_pool_pages_data'  => 'database_pages',
            'Innodb_buffer_pool_pages_dirty' => 'modified_pages',
            'Innodb_buffer_pool_pages_free'  => 'free_pages',
            'Innodb_buffer_pool_pages_total' => 'pool_size',
            'Innodb_data_fsyncs'             => 'file_fsyncs',
            'Innodb_data_pending_reads'      => 'pending_normal_aio_reads',
            'Innodb_data_pending_writes'     => 'pending_normal_aio_writes',
            'Innodb_os_log_pending_fsyncs'   => 'pending_log_flushes',
            'Innodb_pages_created'           => 'pages_created',
            'Innodb_pages_read'              => 'pages_read',
            'Innodb_pages_written'           => 'pages_written',
            'Innodb_rows_deleted'            => 'rows_deleted',
            'Innodb_rows_inserted'           => 'rows_inserted',
            'Innodb_rows_read'               => 'rows_read',
            'Innodb_rows_updated'            => 'rows_updated',
            'Innodb_buffer_pool_reads'       => 'pool_reads',
            'Innodb_buffer_pool_read_requests' => 'pool_read_requests',
        );
     
        # If the SHOW STATUS value exists, override...
        foreach my $key (keys %overrides) {
            if( exists $status{$key} ) {
               debug("Override $key.");
               my $key_val = $overrides{$key};
               $istatus_vals->{$key_val} = $status{$key};
            }
        }
     
        # Now copy the values into $status.
        foreach my $key (keys %$istatus_vals) {
           $status{$key} = $istatus_vals->{$key}
        }
    }

    # Make table_open_cache backwards-compatible (issue 63).
    if( exists $status{'table_open_cache'} ) {
        $status{'table_cache'} = $status{'table_open_cache'};
    }

    # Compute how much of the key buffer is used and unflushed (issue 127).
    $status{'Key_buf_bytes_used'}      = $status{'key_buffer_size'} - $status{'Key_blocks_unused'} * $status{'key_cache_block_size'};
    $status{'Key_buf_bytes_unflushed'} = $status{'Key_blocks_not_flushed'} * $status{'key_cache_block_size'};

    if( exists $status{'unflushed_log'} && $status{'unflushed_log'} ) {
        # TODO: I'm not sure what the deal is here; need to debug this.  But the
        # unflushed log bytes spikes a lot sometimes and it's impossible for it to
        # be more than the log buffer.
        debug("Unflushed log: " . $status{'unflushed_log'});
        $status{'unflushed_log'} = max ($status{'unflushed_log'}, $status{'innodb_log_buffer_size'});
    }

    # Define the variables to output.  I use shortened variable names so maybe
    # it'll all fit in 1024 bytes for Cactid and Spine's benefit.  Strings must
    # have some non-hex characters (non a-f0-9) to avoid a Cacti bug.  This list
    # must come right after the word MAGIC_VARS_DEFINITIONS.  The Perl script
    # parses it and uses it as a Perl variable.
    my %out_keys = (
       'Key_read_requests'           =>  'gg',
       'Key_reads'                   =>  'gh',
       'Key_write_requests'          =>  'gi',
       'Key_writes'                  =>  'gj',
       'history_list'                =>  'gk',
       'innodb_transactions'         =>  'gl',
       'read_views'                  =>  'gm',
       'current_transactions'        =>  'gn',
       'locked_transactions'         =>  'go',
       'active_transactions'         =>  'gp',
       'pool_size'                   =>  'gq',
       'free_pages'                  =>  'gr',
       'database_pages'              =>  'gs',
       'modified_pages'              =>  'gt',
       'pages_read'                  =>  'gu',
       'pages_created'               =>  'gv',
       'pages_written'               =>  'gw',
       'file_fsyncs'                 =>  'gx',
       'file_reads'                  =>  'gy',
       'file_writes'                 =>  'gz',
       'log_writes'                  =>  'hg',
       'pending_aio_log_ios'         =>  'hh',
       'pending_aio_sync_ios'        =>  'hi',
       'pending_buf_pool_flushes'    =>  'hj',
       'pending_chkp_writes'         =>  'hk',
       'pending_ibuf_aio_reads'      =>  'hl',
       'pending_log_flushes'         =>  'hm',
       'pending_log_writes'          =>  'hn',
       'pending_normal_aio_reads'    =>  'ho',
       'pending_normal_aio_writes'   =>  'hp',
       'ibuf_inserts'                =>  'hq',
       'ibuf_merged'                 =>  'hr',
       'ibuf_merges'                 =>  'hs',
       'spin_waits'                  =>  'ht',
       'spin_rounds'                 =>  'hu',
       'os_waits'                    =>  'hv',
       'rows_inserted'               =>  'hw',
       'rows_updated'                =>  'hx',
       'rows_deleted'                =>  'hy',
       'rows_read'                   =>  'hz',
       'Table_locks_waited'          =>  'ig',
       'Table_locks_immediate'       =>  'ih',
       'Slow_queries'                =>  'ii',
       'Open_files'                  =>  'ij',
       'Open_tables'                 =>  'ik',
       'Opened_tables'               =>  'il',
       'innodb_open_files'           =>  'im',
       'open_files_limit'            =>  'in',
       'table_cache'                 =>  'io',
       'Aborted_clients'             =>  'ip',
       'Aborted_connects'            =>  'iq',
       'Max_used_connections'        =>  'ir',
       'Slow_launch_threads'         =>  'is',
       'Threads_cached'              =>  'it',
       'Threads_connected'           =>  'iu',
       'Threads_created'             =>  'iv',
       'Threads_running'             =>  'iw',
       'max_connections'             =>  'ix',
       'thread_cache_size'           =>  'iy',
       'Connections'                 =>  'iz',
       'slave_running'               =>  'jg',
       'slave_stopped'               =>  'jh',
       'running_slave'               =>  'rs',
       'Slave_retried_transactions'  =>  'ji',
       'slave_lag'                   =>  'jj',
       'Slave_open_temp_tables'      =>  'jk',
       'Qcache_free_blocks'          =>  'jl',
       'Qcache_free_memory'          =>  'jm',
       'Qcache_hits'                 =>  'jn',
       'Qcache_inserts'              =>  'jo',
       'Qcache_lowmem_prunes'        =>  'jp',
       'Qcache_not_cached'           =>  'jq',
       'Qcache_queries_in_cache'     =>  'jr',
       'Qcache_total_blocks'         =>  'js',
       'query_cache_size'            =>  'jt',
       'Questions'                   =>  'ju',
       'Com_update'                  =>  'jv',
       'Com_insert'                  =>  'jw',
       'Com_select'                  =>  'jx',
       'Com_delete'                  =>  'jy',
       'Com_replace'                 =>  'jz',
       'Com_load'                    =>  'kg',
       'Com_update_multi'            =>  'kh',
       'Com_insert_select'           =>  'ki',
       'Com_delete_multi'            =>  'kj',
       'Com_replace_select'          =>  'kk',
       'Select_full_join'            =>  'kl',
       'Select_full_range_join'      =>  'km',
       'Select_range'                =>  'kn',
       'Select_range_check'          =>  'ko',
       'Select_scan'                 =>  'kp',
       'Sort_merge_passes'           =>  'kq',
       'Sort_range'                  =>  'kr',
       'Sort_rows'                   =>  'ks',
       'Sort_scan'                   =>  'kt',
       'Created_tmp_tables'          =>  'ku',
       'Created_tmp_disk_tables'     =>  'kv',
       'Created_tmp_files'           =>  'kw',
       'Bytes_sent'                  =>  'kx',
       'Bytes_received'              =>  'ky',
       'innodb_log_buffer_size'      =>  'kz',
       'unflushed_log'               =>  'lg',
       'log_bytes_flushed'           =>  'lh',
       'log_bytes_written'           =>  'li',
       'relay_log_space'             =>  'lj',
       'binlog_cache_size'           =>  'lk',
       'Binlog_cache_disk_use'       =>  'll',
       'Binlog_cache_use'            =>  'lm',
       'binary_log_space'            =>  'ln',
       'innodb_locked_tables'        =>  'lo',
       'innodb_lock_structs'         =>  'lp',
       'State_closing_tables'        =>  'lq',
       'State_copying_to_tmp_table'  =>  'lr',
       'State_end'                   =>  'ls',
       'State_freeing_items'         =>  'lt',
       'State_init'                  =>  'lu',
       'State_locked'                =>  'lv',
       'State_login'                 =>  'lw',
       'State_preparing'             =>  'lx',
       'State_reading_from_net'      =>  'ly',
       'State_sending_data'          =>  'lz',
       'State_sorting_result'        =>  'mg',
       'State_statistics'            =>  'mh',
       'State_updating'              =>  'mi',
       'State_writing_to_net'        =>  'mj',
       'State_none'                  =>  'mk',
       'State_other'                 =>  'ml',
       'Handler_commit'              =>  'mm',
       'Handler_delete'              =>  'mn',
       'Handler_discover'            =>  'mo',
       'Handler_prepare'             =>  'mp',
       'Handler_read_first'          =>  'mq',
       'Handler_read_key'            =>  'mr',
       'Handler_read_next'           =>  'ms',
       'Handler_read_prev'           =>  'mt',
       'Handler_read_rnd'            =>  'mu',
       'Handler_read_rnd_next'       =>  'mv',
       'Handler_rollback'            =>  'mw',
       'Handler_savepoint'           =>  'mx',
       'Handler_savepoint_rollback'  =>  'my',
       'Handler_update'              =>  'mz',
       'Handler_write'               =>  'ng',
       'innodb_tables_in_use'        =>  'nh',
       'innodb_lock_wait_secs'       =>  'ni',
       'hash_index_cells_total'      =>  'nj',
       'hash_index_cells_used'       =>  'nk',
       'total_mem_alloc'             =>  'nl',
       'additional_pool_alloc'       =>  'nm',
       'uncheckpointed_bytes'        =>  'nn',
       'ibuf_used_cells'             =>  'no',
       'ibuf_free_cells'             =>  'np',
       'ibuf_cell_count'             =>  'nq',
       'adaptive_hash_memory'        =>  'nr',
       'page_hash_memory'            =>  'ns',
       'dictionary_cache_memory'     =>  'nt',
       'file_system_memory'          =>  'nu',
       'lock_system_memory'          =>  'nv',
       'recovery_system_memory'      =>  'nw',
       'thread_hash_memory'          =>  'nx',
       'innodb_sem_waits'            =>  'ny',
       'innodb_sem_wait_time_ms'     =>  'nz',
       'Key_buf_bytes_unflushed'     =>  'og',
       'Key_buf_bytes_used'          =>  'oh',
       'key_buffer_size'             =>  'oi',
       'Innodb_row_lock_time'        =>  'oj',
       'Innodb_row_lock_waits'       =>  'ok',
       'Query_time_count_00'         =>  'ol',
       'Query_time_count_01'         =>  'om',
       'Query_time_count_02'         =>  'on',
       'Query_time_count_03'         =>  'oo',
       'Query_time_count_04'         =>  'op',
       'Query_time_count_05'         =>  'oq',
       'Query_time_count_06'         =>  'or',
       'Query_time_count_07'         =>  'os',
       'Query_time_count_08'         =>  'ot',
       'Query_time_count_09'         =>  'ou',
       'Query_time_count_10'         =>  'ov',
       'Query_time_count_11'         =>  'ow',
       'Query_time_count_12'         =>  'ox',
       'Query_time_count_13'         =>  'oy',
       'Query_time_total_00'         =>  'oz',
       'Query_time_total_01'         =>  'pg',
       'Query_time_total_02'         =>  'ph',
       'Query_time_total_03'         =>  'pi',
       'Query_time_total_04'         =>  'pj',
       'Query_time_total_05'         =>  'pk',
       'Query_time_total_06'         =>  'pl',
       'Query_time_total_07'         =>  'pm',
       'Query_time_total_08'         =>  'pn',
       'Query_time_total_09'         =>  'po',
       'Query_time_total_10'         =>  'pp',
       'Query_time_total_11'         =>  'pq',
       'Query_time_total_12'         =>  'pr',
       'Query_time_total_13'         =>  'ps',
       'wsrep_replicated_bytes'      =>  'pt',
       'wsrep_received_bytes'        =>  'pu',
       'wsrep_replicated'            =>  'pv',
       'wsrep_received'              =>  'pw',
       'wsrep_local_cert_failures'   =>  'px',
       'wsrep_local_bf_aborts'       =>  'py',
       'wsrep_local_send_queue'      =>  'pz',
       'wsrep_local_recv_queue'      =>  'qg',
       'wsrep_cluster_size'          =>  'qh',
       'wsrep_cert_deps_distance'    =>  'qi',
       'wsrep_apply_window'          =>  'qj',
       'wsrep_commit_window'         =>  'qk',
       'wsrep_flow_control_paused'   =>  'ql',
       'wsrep_flow_control_sent'     =>  'qm',
       'wsrep_flow_control_recv'     =>  'qn',
       'pool_reads'                  =>  'qo',
       'pool_read_requests'          =>  'qp',
    );

    # return the output.
    my @output;
    foreach my $key (keys %out_keys) {
       # If the value isn't defined, return -1 which is lower than (most graphs')
       # minimum value of 0, so it'll be regarded as a missing value.
       my $short = $out_keys{$key};
       my $val   = defined $status{$key} ? $status{$key} : -1;
       push @output, "$short:$val";
    }

    $result = join(" ", @output);
    open $fp, ">", $cache_file or warn "open file $cache_file error: $!";
    if($fp) {
       eval{
          print $fp $result;
       };
       if( $@ ) {
          die "Can't write $cache_file.\n";
       }
       close $fp;
    }
    return $result;
}

sub str_replace {
   my $str = shift;
   $str =~ tr#:/#__#;
   return $str;
}

# Given INNODB STATUS text, returns a key-value array of the parsed text.  Each
# line shows a sample of the input for both standard InnoDB as you would find in
# MySQL 5.0, and XtraDB or enhanced InnoDB from Percona if applicable.  Note
# that extra leading spaces are ignored due to trim().
sub get_innodb_status {
    my $text = shift;
    my %results = (
        'spin_waits'  => [],
        'spin_rounds' => [],
        'os_waits'    => [],
        'pending_normal_aio_reads'  => undef,
        'pending_normal_aio_writes' => undef,
        'pending_ibuf_aio_reads'    => undef,
        'pending_aio_log_ios'       => undef,
        'pending_aio_sync_ios'      => undef,
        'pending_log_flushes'       => undef,
        'pending_buf_pool_flushes'  => undef,
        'file_reads'                => undef,
        'file_writes'               => undef,
        'file_fsyncs'               => undef,
        'ibuf_inserts'              => undef,
        'ibuf_merged'               => undef,
        'ibuf_merges'               => undef,
        'log_bytes_written'         => undef,
        'unflushed_log'             => undef,
        'log_bytes_flushed'         => undef,
        'pending_log_writes'        => undef,
        'pending_chkp_writes'       => undef,
        'log_writes'                => undef,
        'pool_size'                 => undef,
        'free_pages'                => undef,
        'database_pages'            => undef,
        'modified_pages'            => undef,
        'pages_read'                => undef,
        'pages_created'             => undef,
        'pages_written'             => undef,
        'queries_inside'            => undef,
        'queries_queued'            => undef,
        'read_views'                => undef,
        'rows_inserted'             => undef,
        'rows_updated'              => undef,
        'rows_deleted'              => undef,
        'rows_read'                 => undef,
        'innodb_transactions'       => undef,
        'unpurged_txns'             => undef,
        'history_list'              => undef,
        'current_transactions'      => undef,
        'hash_index_cells_total'    => undef,
        'hash_index_cells_used'     => undef,
        'total_mem_alloc'           => undef,
        'additional_pool_alloc'     => undef,
        'last_checkpoint'           => undef,
        'uncheckpointed_bytes'      => undef,
        'ibuf_used_cells'           => undef,
        'ibuf_free_cells'           => undef,
        'ibuf_cell_count'           => undef,
        'adaptive_hash_memory'      => undef,
        'page_hash_memory'          => undef,
        'dictionary_cache_memory'   => undef,
        'file_system_memory'        => undef,
        'lock_system_memory'        => undef,
        'recovery_system_memory'    => undef,
        'thread_hash_memory'        => undef,
        'innodb_sem_waits'          => undef,
        'innodb_sem_wait_time_ms'   => undef,
    );
    my $txn_seen = 0;
    my $prev_line;
    foreach my $line ( split(/\n/, $text)) {
        $line =~ s/^\s+|\s+$//g;
        my @row = map { if(/^(\d+)[,;:)]/) { $_ = $1 } else { $_ = $_} } split(/\s+/, $line); # trim non-number character.

        # SEMAPHORES
        # Mutex spin waits 79626940, rounds 157459864, OS waits 698719
        if( index($line, 'Mutex spin waits') == 0 ) {
            push @{$results{'spin_waits'}}, tonum($row[3]);
            push @{$results{'spin_rounds'}}, tonum($row[5]);
            push @{$results{'os_waits'}}, tonum($row[8]);
        } elsif ( index($line, 'RW-shared spins') == 0 && index($line, ';') > 0 ) {
            # RW-shared spins 3859028, OS waits 2100750; RW-excl spins 4641946, OS waits 1530310
            push @{$results{'spin_waits'}}, tonum($row[2]);
            push @{$results{'spin_waits'}}, tonum($row[8]);
            push @{$results{'os_waits'}}, tonum($row[5]);
            push @{$results{'os_waits'}}, tonum($row[11]);
        } elsif ( index($line, 'RW-shared spins') == 0 && index($line, '; RW-excl spins') < 0 ) {
            # RW-shared spins 604733, rounds 8107431, OS waits 241268
            push @{$results{'spin_waits'}}, tonum($row[2]);
            push @{$results{'os_waits'}}, tonum($row[7]);
        } elsif ( index($line, 'RW-excl spins') == 0 ) {
            push @{$results{'spin_waits'}}, tonum($row[2]);
            push @{$results{'os_waits'}}, tonum($row[7]);
        } elsif ( index($line, 'seconds the semaphore:') > 0 ) {
            # --Thread 907205 has waited at handler/ha_innodb.cc line 7156 for 1.00 seconds the semaphore:
            $results{'innodb_sem_waits'} += 1;
            $results{'innodb_sem_wait_time_ms'} += tonum($row[9] * 1000);
        }
        # TRANSACTIONS
        elsif ( index($line, 'Trx id counter') == 0 ) {
            # The beginning of the TRANSACTIONS section: start counting transactions
            # Trx id counter 0 1170664159
            # Trx id counter 861B144C
            $results{'innodb_transactions'} = make_bigint(
             $row[3], defined $row[4] ? $row[4] : undef);
            $txn_seen = 1;
        } elsif ( index($line, 'Purge done for trx') == 0 ) {
            # Purge done for trx's n:o < 0 1170663853 undo n:o < 0 0
            # Purge done for trx's n:o < 861B135D undo n:o < 0
            my $purged_to = make_bigint($row[6], $row[7] eq 'undo' ? undef : $row[7]);
            $results{'unpurged_txns'} = $results{'innodb_transactions'} - $purged_to;
        } elsif ( index($line, 'History list length') == 0 ) {
            # History list length 132
            $results{'history_list'} = tonum($row[3]);
        } elsif ( $txn_seen && index($line, '---TRANSACTION') == 0 ) {
            # ---TRANSACTION 0, not started, process no 13510, OS thread id 1170446656
            $results{'current_transaction'} += 1;
            if ( index($line, 'ACTIVE') == 0 ) {
                $results{'active_transaction'} += 1;
            }
        } elsif ( $txn_seen && index($line, '------- TRX HAS BEEN') == 0 ) {
            # ------- TRX HAS BEEN WAITING 32 SEC FOR THIS LOCK TO BE GRANTED:
            $results{'innodb_lock_wait_secs'} += tonum($row[5]);
        } elsif ( index($line, 'read views open inside InnoDB') > 0 ) {
            # 1 read views open inside InnoDB
            $results{'read_views'} = tonum($row[0]);
        } elsif ( index($line, 'mysql tables in use') == 0 ) {
            # mysql tables in use 2, locked 2
            $results{'innodb_tables_in_use'} += tonum($row[4]);
            $results{'innodb_locked_tables'} += tonum($row[6]);
        } elsif ( $txn_seen && index($line, 'lock struct(s)') > 0 ) {
            # 23 lock struct(s), heap size 3024, undo log entries 27
            # LOCK WAIT 12 lock struct(s), heap size 3024, undo log entries 5
            # LOCK WAIT 2 lock struct(s), heap size 368
            if ( index($line, 'LOCK WAIT') == 0 ) {
                $results{'innodb_lock_structs'} += tonum($row[2]);
                $results{'locked_transactions'} += 1;
            } else {
                $results{'innodb_lock_structs'} += tonum($row[0]);
            }
        }
        # FILE I/O
        elsif ( index($line, ' OS file reads, ') > 0 ) {
            # 8782182 OS file reads, 15635445 OS file writes, 947800 OS fsyncs
            $results{'file_reads'}  = tonum($row[0]);
            $results{'file_writes'} = tonum($row[4]);
            $results{'file_fsyncs'} = tonum($row[8]);
        } elsif ( index($line, 'Pending normal aio reads:') == 0 ) {
            # Pending normal aio reads: 0, aio writes: 0,
            $results{'pending_normal_aio_reads'}  = tonum($row[4]);
            $results{'pending_normal_aio_writes'} = tonum($row[7]);
        } elsif ( index($line, 'ibuf aio reads') == 0 ) {
            #  ibuf aio reads: 0, log i/o's: 0, sync i/o's: 0
            $results{'pending_ibuf_aio_reads'}   = tonum($row[3]);
            $results{'pending_aio_log_ios'}      = tonum($row[6]);
            $results{'pending_aio_sync_flushes'} = tonum($row[9]);
        } elsif ( index($line, 'Pending flushes (fsync)') == 0 ) {
            # Pending flushes (fsync) log: 0; buffer pool: 0
            $results{'pending_log_flushes'}      = tonum($row[4]);
            $results{'pending_buf_pool_flushes'} = tonum($row[7]);
        }
        # INSERT BUFFER AND ADAPTIVE HASH INDEX
        elsif ( index($line, 'Ibuf for space 0: size ') == 0 ) {
            # Older InnoDB code seemed to be ready for an ibuf per tablespace.  It
            # had two lines in the output.  Newer has just one line, see below.
            # Ibuf for space 0: size 1, free list len 887, seg size 889, is not empty
            # Ibuf for space 0: size 1, free list len 887, seg size 889,
            $results{'ibuf_used_cells'} = tonum($row[5]);
            $results{'ibuf_free_cells'} = tonum($row[9]);
            $results{'ibuf_cell_count'} = tonum($row[12]);
        } elsif ( index($line, 'Ibuf: size ') == 0 ) {
            # Ibuf: size 1, free list len 4634, seg size 4636,
            $results{'ibuf_used_cells'} = tonum($row[2]);
            $results{'ibuf_free_cells'} = tonum($row[6]);
            $results{'ibuf_cell_count'} = tonum($row[9]);
            if( index($line, 'merges') >= 0 ) {
                $results{'ibuf_merges'} = tonum($row[10]);
            }
        } elsif ( index($line, ', delete mark ') > 0 && index($prev_line, 'merged operations:') == 0 ) {
            # Output of show engine innodb status has changed in 5.5
            # merged operations:
            # insert 593983, delete mark 387006, delete 73092
            $results{'ibuf_inserts'} = tonum($row[1]);
            $results{'ibuf_merged'}  = tonum($row[1]) + tonum($row[4]) + tonum($row[6]);
        } elsif ( index($line, ' merged recs, ') > 0 ) {
            # 19817685 inserts, 19817684 merged recs, 3552620 merges
            $results{'ibuf_inserts'} = tonum($row[0]);
            $results{'ibuf_merged'}  = tonum($row[2]);
            $results{'ibuf_merges'}  = tonum($row[5]);
        } elsif ( index($line, 'Hash table size ') == 0 ) {
            # In some versions of InnoDB, the used cells is omitted.
            # Hash table size 4425293, used cells 4229064, ....
            # Hash table size 57374437, node heap has 72964 buffer(s) <-- no used cells
            $results{'hash_index_cells_total'} = tonum($row[3]);
            $results{'hash_index_cells_used'}  = index($line, 'used cells') > 0 ? tonum($row[6]) : 0;
        }
        # LOG
        elsif ( index($line, " log i/o's done, ") > 0 ) {
            # 3430041 log i/o's done, 17.44 log i/o's/second
            # 520835887 log i/o's done, 17.28 log i/o's/second, 518724686 syncs, 2980893 checkpoints
            # TODO: graph syncs and checkpoints
            $results{'log_writes'} = tonum($row[0]);
        } elsif ( index($line, ' pending log writes, ') > 0 ) {
            # 0 pending log writes, 0 pending chkp writes
            $results{'pending_log_writes'}  = tonum($row[0]);
            $results{'pending_chkp_writes'} = tonum($row[4]);
        } elsif ( index($line, 'Log sequence number') == 0 ) {
            # This number is NOT printed in hex in InnoDB plugin.
            # Log sequence number 13093949495856 //plugin
            # Log sequence number 125 3934414864 //normal
            $results{'log_bytes_written'} = defined $row[4]
                                          ? make_bigint($row[3], $row[4])
                                          : tonum($row[3]);
        } elsif ( index($line, 'Log flushed up to') == 0 ) {
            # This number is NOT printed in hex in InnoDB plugin.
            # Log flushed up to   13093948219327
            # Log flushed up to   125 3934414864
            $results{'log_bytes_flushed'} = defined $row[5]
                                          ? make_bigint($row[4], $row[5])
                                          : tonum($row[4]);
        } elsif ( index($line, 'Last checkpoint at') == 0 ) {
            # Last checkpoint at  125 3934293461
            $results{'last_checkpoint'} = defined $row[4]
                                        ? make_bigint($row[3], $row[4])
                                        : tonum($row[3]);
        }
        # BUFFER POOL AND MEMORY
        elsif ( index($line, 'Total memory allocated') == 0 && index($line, 'in additional pool allocated') > 0 ) {
           # Total memory allocated 29642194944; in additional pool allocated 0
           # Total memory allocated by read views 96
           $results{'total_mem_alloc'}       = tonum($row[3]);
           $results{'additional_pool_alloc'} = tonum($row[8]);
        } elsif ( index($line, 'Adaptive hash index ') == 0 ) {
           #  Adaptive hash index 1538240664 	(186998824 + 1351241840)
           $results{'adaptive_hash_memory'} = tonum($row[3]);
        } elsif ( index($line, 'Page hash           ') == 0 ) {
           #  Page hash           11688584
           $results{'page_hash_memory'} = tonum($row[2]);
        } elsif ( index($line, 'Dictionary cache    ') == 0 ) {
           #  Dictionary cache    145525560 	(140250984 + 5274576)
           $results{'dictionary_cache_memory'} = tonum($row[2]);
        } elsif ( index($line, 'File system         ') == 0 ) {
           #  File system         313848 	(82672 + 231176)
           $results{'file_system_memory'} = tonum($row[2]);
        } elsif ( index($line, 'Lock system         ') == 0 ) {
           #  Lock system         29232616 	(29219368 + 13248)
           $results{'lock_system_memory'} = tonum($row[2]);
        } elsif ( index($line, 'Recovery system     ') == 0 ) {
           #  Recovery system     0 	(0 + 0)
           $results{'recovery_system_memory'} = tonum($row[2]);
        } elsif ( index($line, 'Threads             ') == 0 ) {
           #  Threads             409336 	(406936 + 2400)
           $results{'thread_hash_memory'} = tonum($row[1]);
        } elsif ( index($line, 'innodb_io_pattern   ') == 0 ) {
           #  innodb_io_pattern   0 	(0 + 0)
           $results{'innodb_io_pattern_memory'} = tonum($row[1]);
        } elsif ( index($line, 'Buffer pool size ') == 0 ) {
           # The " " after size is necessary to avoid matching the wrong line:
           # Buffer pool size        1769471
           # Buffer pool size, bytes 28991012864
           $results{'pool_size'} = tonum($row[3]);
        } elsif ( index($line, 'Free buffers') == 0 ) {
           # Free buffers            0
           $results{'free_pages'} = tonum($row[2]);
        } elsif ( index($line, 'Database pages') == 0 ) {
           # Database pages          1696503
           $results{'database_pages'} = tonum($row[2]);
        } elsif ( index($line, 'Modified db pages') == 0 ) {
           # Modified db pages       160602
           $results{'modified_pages'} = tonum($row[3]);
        } elsif ( index($line, 'Pages read ahead') == 0 ) {
           # Must do this BEFORE the next test, otherwise it'll get fooled by this
           # line from the new plugin (see samples/innodb-015.txt):
           # Pages read ahead 0.00/s, evicted without access 0.06/s
           # TODO: No-op for now, see issue 134.
        } elsif ( index($line, 'Pages read') == 0 ) {
           # Pages read 15240822, created 1770238, written 21705836
           $results{'pages_read'}    = tonum($row[2]);
           $results{'pages_created'} = tonum($row[4]);
           $results{'pages_written'} = tonum($row[6]);
        }
        # ROW OPERATIONS
        elsif ( index($line, 'Number of rows inserted') == 0 ) {
           # Number of rows inserted 50678311, updated 66425915, deleted 20605903, read 454561562
           $results{'rows_inserted'} = tonum($row[4]);
           $results{'rows_updated'}  = tonum($row[6]);
           $results{'rows_deleted'}  = tonum($row[8]);
           $results{'rows_read'}     = tonum($row[10]);
        } elsif( index($line, ' queries inside InnoDB, ') > 0 ) {
           # 0 queries inside InnoDB, 0 queries in queue
           $results{'queries_inside'} = tonum($row[0]);
           $results{'queries_queued'} = tonum($row[4]);
        }
        $prev_line = $line;
    }

    foreach ( 'spin_waits', 'spin_rounds', 'os_waits' ) {
        $results{$_} = tonum(sum @{$results{$_}});
    }

    $results{'unflushed_log'}        = $results{'log_bytes_written'} - $results{'log_bytes_flushed'};
    $results{'uncheckpointed_bytes'} = $results{'log_bytes_written'} - $results{'last_checkpoint'};

    return \%results;
}

# takes only numbers from a string
sub tonum {
    my $str = shift;
    return 0 if !$str;
    return new Math::BigInt $1 if $str =~ m/(\d+)/;
    return 0;
}

# return a 64 bit number from either an hex encoding or
# a hi lo representation
sub make_bigint {
    my ($hi, $lo) = @_;
    no warnings 'portable';
    unless ($lo) {
        $hi = new Math::BigInt '0x' . $hi;
        return $hi;
    }

    $hi = new Math::BigInt $hi;
    $lo = new Math::BigInt $lo;
    return $lo->badd($hi->blsft(32));
}

=pod

=head1 CONFIGURE MYSQL CONNECTIVITY ON AGENT

   1. Create .cnf file /home/mysql/.my.cnf, this script read it and parse username 
and password. Example:

      [client]
      user=monitoruser
      password=monitorpass

   2. Change mymonitor.pl user and pass as hard code in script, in line 29 and 30,
Example:

      29 my $user     = 'monitoruser';
      30 my $password = 'monitorpass';

   3. Parameters for options.

      --user  MySQL username
      --pass  MySQL password

=head1 OPTIONS


=head2 options

  --host      MySQL host
  --items     Comma-separated list of the items whose data you want
  --user      MySQL username
  --pass      MySQL password
  --port      MySQL port
  --charset   MySQL charset
  --nocache   Do not cache results in a file
  --ssl       Whether use ssl to connect MySQL or not
  --polltime  The expire time for cache
  --debug     Print Debug info
  --help      Show usage


=head1 AUTHOR

zhe.chen <chenzhe07@gmail.com>

2015-03-10

=head1 CHANGELOG

v0.1.0 version

=cut

package MySQL::dbh;
# Get the database handle which user use, and this database 
# handle object should be destroy when leave MySQL database.

use strict;
use warnings FATAL => 'all';
use constant PTDEBUG => $ENV{PTDEBUG} || 0;
use English qw(-no_match_vars);
use DBI;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);

use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

require Exporter;
@ISA = qw(Exporter);
@EXPORT    = qw( get_dbh disconnect );
$VERSION = '0.1.0';

eval {
    require DBI;
};


if ( $@ ) {
    die "Cannot connect to MySQL because the Perl DBI module is not "
       . "installed or not found.  Run 'perl -MDBI' to see the directories "
       . "that Perl searches for DBI.  If DBI is not installed, try:\n"
       . "  Debian/Ubuntu  apt-get install libdbi-perl\n"
       . "  RHEL/CentOS    yum install perl-DBI\n"
       . "  OpenSolaris    pkg install pkg:/SUNWpmdbi\n";
}

sub host {
    my $self = shift;
    $self->{host} = shift if @_;
    return $self->{host};
}

sub port {
    my $self = shift;
    $self->{port} = shift if @_;
    return $self->{port};
}

sub user {
    my $self = shift;
    $self->{user} = shift if @_;
    return $self->{user};
}

sub password {
    my $self = shift;
    $self->{password} = shift if @_;
    return $self->{password};
}

sub charset {
    my $self = shift;
    $self->{charset} = shift if @_;
    return $self->{charset};
}

sub driver {
    my $self = shift;
    $self->{driver} = shift if @_;
    return $self->{driver};
}

sub new {
    my ($class, %args) = @_;
    my @required_args = qw(host port user password);
    PTDEBUG && print Dumper(%args);

    foreach my $arg (@required_args) {
        die "I need a $arg argument" unless $args{$arg};
    }

    my $self = {};
    bless $self, $class;

    # options should be used.
    $self->host($args{'host'} || 127.0.0.1);
    $self->port($args{'port'} || 3306);
    $self->user($args{'user'} || 'audit');
    $self->password($args{'password'} || '');
    $self->charset($args{'charset'} || 'utf8');
    $self->driver($args{'driver'} || 'mysql');

    return $self;
}

sub get_dbh {
    my ($self, $database, $opts) = @_;
    $opts ||= {};
    my $host = $self->{host};
    my $port = $self->{port};
    my $user = $self->{user};
    my $password = $self->{password};
    my $charset  = $self->{charset};
    my $driver   = $self->{driver};
    
    my $defaults = {
        AutoCommit         => 0,
        RaiseError         => 1,
        PrintError         => 0,
        ShowErrorStatement => 1,
        mysql_enable_utf8 => ($charset =~ m/utf8/i ? 1 : 0),
    };
    @{$defaults}{ keys %$opts } = values %$opts;

    if ( $opts->{mysql_use_result} ) {
        $defaults->{mysql_use_result} = 1;
    }

    my $dbh;
    my $tries = 2;
    while ( !$dbh && $tries-- ) {
        PTDEBUG && print Dumper(join(', ', map { "$_=>$defaults->{$_}" } keys %$defaults ));
        $dbh = eval { DBI->connect("DBI:$driver:database=$database;host=$host;port=$port", $user, $password, $defaults)};

        if( !$dbh && $@ ) {
            if ( $@ =~ m/locate DBD\/mysql/i ){
                die "Cannot connect to MySQL because the Perl DBD::mysql module is "
                   . "not installed or not found.  Run 'perl -MDBD::mysql' to see "
                   . "the directories that Perl searches for DBD::mysql.  If "
                   . "DBD::mysql is not installed, try:\n"
                   . "  Debian/Ubuntu  apt-get install libdbd-mysql-perl\n"
                   . "  RHEL/CentOS    yum install perl-DBD-MySQL\n"
                   . "  OpenSolaris    pgk install pkg:/SUNWapu13dbd-mysql\n";
            } elsif ( $@ =~ m/not a compiled character set|character set utf8/i ) {
                PTDEBUG && print 'Going to try again without utf8 support\n'; 
                delete $defaults->{mysql_enable_utf8};
            }
            if ( !$tries ) {
                die "$@";
            }

        }
    }

    if ( $driver =~ m/mysql/i ) {
        my $sql;
        $sql = 'SELECT @@SQL_MODE';
        PTDEBUG && print "+-- $sql\n";

        my ( $sql_mode ) = eval { $dbh->selectrow_array($sql) };
          die "Error getting the current SQL_MORE: $@" if $@;

        if ( $charset ) {
            $sql = qq{/*!40101 SET NAMES "$charset"*/};
            PTDEBUG && print "+-- $sql\n";
            eval { $dbh->do($sql) };
              die "Error setting NAMES to $charset: $@" if $@;
            PTDEBUG && print "Enabling charset to STDOUT\n";
            if ($charset eq 'utf8') {
                binmode(STDOUT, ':utf8')
                     or die "Can't binmode(STDOUT, ':utf8'): $!\n";
            } else {
                binmode(STDOUT) or die "Can't binmode(STDOUT): $!\n";
            }
        }

        $sql = 'SET @@SQL_QUOTE_SHOW_CREATE = 1'
              . '/*!40101, @@SQL_MODE=\'NO_AUTO_VALUE_ON_ZERO'
              . ($sql_mode ? ",$sql_mode" : '')
              . '\'*/';
        PTDEBUG && print "+-- $sql\n";
        eval {$dbh->do($sql)};
        die "Error setting SQL_QUOTE_SHOW_CREATE, SQL_MODE" . ($sql_mode ? " and $sql_mode" : '') . ": $@" if $@;
    }

    if ( PTDEBUG ) {
        print Dumper($dbh->selectrow_hashref('SELECT DATABASE(), CONNECTION_ID(), VERSION()/*!50038, @@hostname*/')) ;
        print "+-- 'Connection info:', $dbh->{mysql_hostinfo}\n";
        print Dumper($dbh->selectall_arrayref("SHOW VARIABLES LIKE 'character_set%'", { Slice => {}}));
        print '+-- $DBD::mysql::VERSION:' . "$DBD::mysql::VERSION\n";
        print '+-- $DBI::VERSION:' . "$DBI::VERSION\n";
    }
    return $dbh;
}

# handle should be destroy.
sub disconnect {
    my($self, $dbh) = @_;
    PTDEBUG && $self->print_active_handles($self->get_dbh);
    $dbh->disconnect;
}

sub print_active_handles {
   my ( $self, $thing, $level ) = @_;
   $level ||= 0;
   printf("# Active %sh: %s %s %s\n", ($thing->{Type} || 'undef'), "\t" x $level,
      $thing, (($thing->{Type} || '') eq 'st' ? $thing->{Statement} || '' : ''))
      or die "Cannot print: $OS_ERROR";
   foreach my $handle ( grep {defined} @{ $thing->{ChildHandles} } ) {
      $self->print_active_handles( $handle, $level + 1 );
   }
}

1; # Because this is a module as well as a script.

###################################################################################################
# Documentation.
# #################################################################################################

=pod

=head1 NAME

  MySQL::dbh - Get the database handle which is specified by script.

=head1 SYNOPSIS

Examples:

      use MySQL::dbh;

      my $dblist = MySQL::dbh->new(
          host     => '127.0.0.1',
          port     => 3306,
          user     => 'username',
          password => 'password',
          charset  => 'utf8',
          driver   => 'mysql',
      );

      # specify the database name.
      my $db_handle = $dblist->get_dbh('test',{AutoCommit => 1});
      my $sql = 'SHOW TABLES';

      # execute sql as DBI or DBD::mysql.
      my $table = $db_handle->selectall_arrayref($sql);
      $dblist->disconnect($db_handle);

Note that above script will exit, if disconnect MySQL. different database name
can be assigned to get_dbh method.

=head1 RISKS

It assumes just only one audit user used, and well tested, but different 
databases will be used by developer members. The module does not check 
whether the specified database is exists or not.

=head1 AUTHOR

zhe.chen <chenzhe07@gmail.com>

=head1 CHANGELOG

v0.1.0 version

=cut
