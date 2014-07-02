#!/usr/bin/perl
#
#   $Id$
#
#   catwho.pl, lists registered active sessions
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
use catty::configure::catwho;
use catty::user;

# Библиотеки пакета

use debug qw(:debug_levels);
use timestamp;

# Библиотеки "слева"

use Getopt::Std;
use DBI;
use POSIX qw(strftime);
use Crypt::PasswdMD5;


# Получаем конфигурационные данные

my $conf = catty::configure::catwho->new;
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
    DEBUG_DEBUG, "Connecting to SQL-server at " . $conf->{'mysql_c_host'}
);
my $dbh_c = DBI->connect(
    "DBI:mysql:database=" . $conf->{'mysql_c_db'} .
        ";host=" . $conf->{'mysql_c_host'},
    $conf->{'mysql_c_login'},
    $conf->{'mysql_c_passwd'},
    {
        PrintError => 0
    }
);
unless (defined($dbh_c)) {
    $debug->write(DEBUG_ERROR, "Can't DBI::db->connect(): $DBI::errstr");
    exit(-1);
}


# Который час?

my $time_now = strftime("%Y-%m-%d %H:%M:%S", localtime);
$debug->write(
    DEBUG_DEBUG,
    "System clock shows: $time_now (" . timestamp2unixtime($time_now) . ")"
);


# Основной цикл

my $exit_status;

while (1) {

    # Подготавливаем SQL-транзакции
        
    my $sth_get_manager = $dbh_c->prepare(
        "SELECT " .
            "mid, " .
            "mlevel " .
        "FROM managers " .
        "WHERE " .
            "mlogin = ? AND " .
            "mactive != 0"
    );

    my $sth_get_sessions = $dbh_c->prepare(
        "SELECT " .
            "users.ulogin, " .
            "nases.naddr, " .
            "sessions.snasport, " .
            "sessions.scsid, " .
            "sessions.stime_start, " .
            "sessions.scost " .
        "FROM " .
            "users, " .
            "nases, " .
            "sessions " .
        "WHERE " .
            "users.ulevel <= ? AND " .
            "users.uid = sessions.suser AND " .
            "nases.nid = sessions.snas AND " .
            "sessions.stime_stop = '0000-00-00 00:00:00'"
    );


    # Получаем сведения о менеджере

    $debug->write(DEBUG_DEBUG, "Getting ID of manager");
    
    unless (defined($sth_get_manager->execute($conf->{'manager'}))) {
        $debug->write(DEBUG_ERROR, "Can't DBI::st->execute(): " . $dbh_c->errstr);
        $exit_status = -1;
        last;
    }
    
    my ($mid, $mlevel) = $sth_get_manager->fetchrow_array();
    
    unless (defined($sth_get_manager->finish)) {
        $debug->write(DEBUG_ERROR, "Can't DBI::st->finish(): " . $dbh_c->errstr);
        $exit_status = -1;
        last;
    }
    
    unless (defined($mid) && defined($mlevel)) {
        $debug->write(DEBUG_ERROR, "Can't recognize manager '$conf->{'manager'}'");
        $exit_status = -1;
        last;
    }
    
    $debug->write(
        DEBUG_DEBUG,
        "Manager $conf->{'manager'} has ID $mid and level $mlevel"
    );


    # Получаем список сессий

    $debug->write(DEBUG_DEBUG, "Getting list of active sessions");

    unless (defined($sth_get_sessions->execute($mlevel))) {
        $debug->write(DEBUG_ERROR, "Can't DBI::st->execute(): " . $dbh_c->errstr);
        $exit_status = -1;
        last;
    }

    while (my (
        $ulogin,
        $naddr,
        $snasport,
        $scsid,
        $stime_start,
        $scost
    ) = $sth_get_sessions->fetchrow_array) {
        $scsid = "-" unless (length($scsid));
        printf("%16s %25s\t%12s\t%19s\t%.5f\n",
            $ulogin,
            "$naddr:$snasport",
            $scsid,
            $stime_start,
            $scost
        );
    }

    unless (defined($sth_get_sessions->finish)) {
        $debug->write(DEBUG_ERROR, "Can't DBI::st->finish(): " . $dbh_c->errstr);
        $exit_status = -1;
        last;
    }

    last;

}


# Отключение от SQL-сервера

$debug->write(
    DEBUG_DEBUG,
    "Disconnecting from MySQL-server at " . $conf->{'mysql_c_host'}
);
unless (defined($dbh_c->disconnect)) {
    $debug->write(DEBUG_ERROR, "Can't DBI::db->close(): " . $dbh_c->errstr);
}


# Закрытие интерфейса протоколирования

$debug->write(
    DEBUG_DEBUG, "My last words before I will close logs"
);
unless (defined($debug->close)) {
    warn("Can't debug->close(): $debug->{'error'}");
    # exit(-1);
}

exit($exit_status);

