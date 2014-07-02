#!/usr/bin/perl
#
#   $Id$
#
#   dialup_report.pl, generating report :)
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
use catty::configure::dialup_report;
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

my $conf = catty::configure::dialup_report->new;
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


# Производим проверки параметров запуска

unless (defined($conf->{'start_time'})) {
    $debug->write(DEBUG_ERROR, "Undefined start time");
    exit(-1);
}
unless (defined($conf->{'stop_time'})) {
    $conf->{'stop_time'} = $time_now;
}


# Основной цикл

my $exit_status;

MAIN_LOOP:
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

    my $sth_get_packages = $dbh_c->prepare(
        "SELECT " .
            "kid, " .
            "kname " .
        "FROM packages"
    );

    my $sth_get_sessions = $dbh_c->prepare(
        "SELECT " .
            "users.upack, " .
            "COUNT(sid) " .
        "FROM " .
            "sessions, " .
            "users " .
        "WHERE " .
            "sessions.stime_start >= ? AND " .
            "sessions.stime_stop < ? AND " .
            "sessions.suser = users.uid " .
        "GROUP BY users.upack"
    );


    # Получаем сведения о менеджере

    $debug->write(DEBUG_DEBUG, "Getting ID of manager");
    
    unless (defined($sth_get_manager->execute($conf->{'manager'}))) {
        $debug->write(DEBUG_ERROR, "Can't DBI::st->execute(): " . $dbh_c->errstr);
        $exit_status = -1;
        last MAIN_LOOP;
    }
    
    my ($mid, $mlevel) = $sth_get_manager->fetchrow_array();
    
    unless (defined($sth_get_manager->finish)) {
        $debug->write(DEBUG_ERROR, "Can't DBI::st->finish(): " . $dbh_c->errstr);
        $exit_status = -1;
        last MAIN_LOOP;
    }
    
    unless (defined($mid) && defined($mlevel)) {
        $debug->write(DEBUG_ERROR, "Can't recognize manager '$conf->{'manager'}'");
        $exit_status = -1;
        last MAIN_LOOP;
    }
    
    $debug->write(
        DEBUG_DEBUG,
        "Manager $conf->{'manager'} has ID $mid and level $mlevel"
    );


    # Получаем список тарифных пакетов

    my %packages;

    $debug->write(DEBUG_DEBUG, "Getting list of packages");

    unless (defined($sth_get_packages->execute)) {
        $debug->write(DEBUG_ERROR, "Can't DBI::st->execute(): " . $dbh_c->errstr);
        $exit_status = -1;
        last MAIN_LOOP;
    }

    while (my ($kid, $kname) = $sth_get_packages->fetchrow_array) {
        $debug->write(DEBUG_DEBUG, "Found package $kname ($kid)");

        $packages{$kid} = $kname;
    }

    unless (defined($sth_get_packages->finish)) {
        $debug->write(DEBUG_ERROR, "Can't DBI::st->finish(): " . $dbh_c->errstr);
        $exit_status = -1;
        last MAIN_LOOP;
    }

    unless (scalar(keys(%packages))) {
        $debug->write(DEBUG_ERROR, "No packages found");
        $exit_status = -1;
        last MAIN_LOOP;
    }


    # Запускаем цикл сбора данных

    my $step = 60;

    for (
        my $time = timestamp2unixtime($conf->{'start_time'});
           $time < timestamp2unixtime($conf->{'stop_time'});
           $time = $time + $step
    ) {
        if ($time == timestamp2unixtime($conf->{'start_time'})) {
            foreach my $package (sort {$a <=> $b} (keys(%packages))) {
                print($packages{$package} . ";");
            }
            print("Время\n");
        }
        $debug->write(
            DEBUG_DEBUG,
            "Getting stats for " . unixtime2timestamp($time)
        );
        unless (defined($sth_get_sessions->execute(
            unixtime2timestamp($time),
            unixtime2timestamp($time + $step)
        ))) {
            $debug->write(
                DEBUG_ERROR, "Can't DBI::st->execute()" . $dbh_c->errstr
            );
            $exit_status = -1;
            last MAIN_LOOP;
        }

        my %sessions;
        while (my ($package, $sessions) = $sth_get_sessions->fetchrow_array) {
            $sessions{$package} = $sessions;            
        }

        unless (defined($sth_get_sessions->finish)) {
            $debug->write(
                DEBUG_ERROR,
                "Can't DBI::st->finish()" . $dbh_c->errstr
            );
            $exit_status = -1;
            last MAIN_LOOP;
        }

        foreach my $package (sort {$a <=> $b} (keys(%packages))) {
            if (defined($sessions{$package})) {
                print($sessions{$package} . ";");
            } else {
                print("0;");
            }
        }

        print("$time\n");
    }


    last MAIN_LOOP;

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

