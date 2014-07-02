#!/usr/bin/perl
#
#   $Id$
#
#   account_check.pl, checks account for specified user
#   Copyright (C) 2002, 2003  V.Melnik <melnik@raccoon.kiev.ua>
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#

# All comments writen in Russian


use strict;

use FindBin qw($Bin);

use lib "$Bin/../lib";

# Модули пакета

use catty::config qw(
    :CATTY_main
);
use catty::configure::terminator_intercom;
use catty::user;

# Библиотеки пакета

use debug qw(:debug_levels);
use timestamp;

# Библиотеки "слева"

use Getopt::Std;
use DBI;
use POSIX qw(strftime);


# Получаем конфигурационные данные

my $conf = catty::configure::terminator_intercom->new;
unless (defined($conf)) {
    exit(-1);
}


# Открываем интерфейс протоколирования 

my ($debug, $debug_error) = debug->new(
    debug_level_logfile => $conf->{'log_level'},
    debug_level_stdout  => DEBUG_QUIET,
    debug_level_stderr  => DEBUG_WARNING,
    logfile             => $conf->{'log_file'}
);
unless (defined($debug)) {
    die("Can't debug->new(): $debug_error");
}
unless (defined($debug->reopen)) {
    die("Can't debug->reopen(): $debug->{'error'}");
}


# Подключаемся к SQL

$debug->write(
    DEBUG_DEBUG, "Connecting to SQL-server at " . $conf->{'mysql_r_host'}
);
my $dbh_r = DBI->connect(
    "DBI:mysql:database=" . $conf->{'mysql_r_db'} .
        ";host=" . $conf->{'mysql_r_host'},
    $conf->{'mysql_r_login'},
    $conf->{'mysql_r_passwd'},
    {
        PrintError => 0
    }
);
unless (defined($dbh_r)) {
    $debug->write(DEBUG_ERROR, "Can't DBI::db->connect(): $DBI::errstr");
    exit(-1);
}


# Получаем список сессий для уёббинга

my $sth_get_acct_session_id = $dbh_r->prepare(
    "SELECT AcctSessionId " .
    "FROM radacct " .
    "WHERE " .
        "NASIPAddress = ? AND " .
        "NASPortId = ? AND " .
        "AcctStopTime = '0000-00-00 00:00:00'"
);

my @sessions_to_reset;

while (<STDIN>) {

    chomp;

    if (/^\s*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}):Async(\d+)\s*$/i) {
        my $nas_ip_address = $1;
        my $nas_port_id = $2;

        $debug->write(DEBUG_DEBUG, "Got $nas_ip_address $nas_port_id");

        unless ($sth_get_acct_session_id->execute(
            $nas_ip_address,
            $nas_port_id
        )) {
            $debug->write(
                DEBUG_ERROR,
                "Can't DBI::st->execute(): " . $dbh_r->errstr
            );
            next;
        }

        my $rows_found;
        while (my ($acct_session_id) = $sth_get_acct_session_id->fetchrow_array) {
            $rows_found++;
            $debug->write(
                DEBUG_DEBUG,
                "Identified as AcctSessionId $acct_session_id ($rows_found)"
            );
            push(@sessions_to_reset, $acct_session_id);
        }
        unless ($rows_found > 0) {
            $debug->write(
                DEBUG_WARNING,
                "Can't find any session for this NASIPAddress/NASPortId-pair"
            );
        }
        
    } else {

        $debug->write(DEBUG_WARNING, "Invalid request: '$_'");

    }
}


# Отключение от SQL-сервера

$debug->write(
    DEBUG_DEBUG,
    "Disconnecting from MySQL-server at " . $conf->{'mysql_r_host'}
);
unless (defined($dbh_r->disconnect)) {
    $debug->write(DEBUG_ERROR, "Can't DBI::db->close(): " . $dbh_r->errstr);
}


# Сброс сессий

foreach my $acct_session_id (@sessions_to_reset) {

    $debug->write(DEBUG_INFO, "Terminating session $acct_session_id");

    my $new_pid = open(SSH, '|-');

    if (! defined($new_pid)) {

        $debug->write(DEBUG_ERROR, "Can't fork(): $!");
        next;
    
    } elsif ($new_pid > 0) {

        print(SSH "$acct_session_id\n");

        unless (defined(close(SSH))) {
            $debug->write(DEBUG_ERROR, "Can't close(): $!");
            next;
        }
    
    } else {

        unless (defined(exec(
            '/usr/bin/ssh',
                'silvercom@billing.intercom.net.ua'
        ))) {
            die("Can't exec(): $!");
        }
    
    }

}


# Закрытие интерфейса протоколирования

$debug->write(
    DEBUG_DEBUG, "My last words before I will close logs"
);
unless (defined($debug->close)) {
    warn("Can't debug->close(): $debug->{'error'}");
    # exit(-1);
}


