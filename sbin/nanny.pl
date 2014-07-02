#!/usr/bin/perl
#
#   $Id: nanny.pl,v 1.21 2003/04/21 19:34:05 melnik Exp $
#
#   nanny.pl, supervisor module which observes connected users
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


# ���� ����������� ����� ��������...    (12-07-2002)
# ��� �� ��� ��� ��� �����������!       (16-07-2002)
# ��, �� ���� ����� �� ��������! ;-)    (08-04-2003)
# ������ �����������, � ��������.       (09-04-2003)
# �� ���, �� ������ ��������!           (10-04-2003)
# � ��� �� �����                        (18-02-2004)

use strict;

use FindBin qw($Bin);

use lib "$Bin/../lib";

# ������ ������

use catty::config qw(
    :CATTY_main
);
use catty::configure::nanny;
use catty::nas;
use catty::user;
use catty::session;

# ���������� ������

use debug qw(:debug_levels);
use timestamp;

# ���������� "�����"

use Getopt::Std;
use DBI;
use POSIX qw(setsid setuid getuid getpwnam setgid getgid getgrnam strftime);


# �������� ���������������� ������

my $conf = catty::configure::nanny->new;
unless (defined($conf)) {
    exit(-1);
}


# �������� ���� UID � GID

if (defined($conf->{'user'})) {
    my $pwuid = getpwnam($conf->{'user'});
    unless (defined($pwuid)) {
        die("Can't getpwnam(): $!");
    }
    if ($pwuid != getuid()) {
        unless (defined(setuid($pwuid))) {
            die("Can't setuid(): $!");
        }
    }
}
if (defined($conf->{'group'})) {
    my $grgid = getgrnam($conf->{'group'});
    unless (defined($grgid)) {
        die("Can't getgrnam(): $!");
    }
    if ($grgid != getgid()) {
        unless (defined(setgid($grgid))) {
            die("Can't setgid(): $!");
        }
    }
}


# ��������� ��������� ���������������� 

my ($debug, $debug_error) = debug->new(
    debug_level_logfile => $conf->{'log_level'},
    debug_level_stdout  => DEBUG_QUIET,
    debug_level_stderr  => DEBUG_QUIET,
    logfile             => $conf->{'log_file'}
);
unless (defined($debug)) {
    die("Can't debug->new(): $debug_error");
}
unless (defined($debug->reopen)) {
    die("Can't debug->reopen(): $debug->{'error'}");
}


# �������������� ��� �������������

if ($conf->{'be_daemon'}) {
    $debug->write(DEBUG_DEBUG, "Daemonizing");

    my $new_pid = fork;

    if (! defined($new_pid)) {
        $debug->write(DEBUG_ERROR, "Can't fork(): $!");
        exit(-1);
    } elsif ($new_pid > 0) {
        $debug->write(DEBUG_DEBUG, "New child has borned with PID $new_pid");
        exit(0);
    } else {
        unless (defined($debug->reopen)) {
            die("Can't debug->reopen(): $debug->{'error'}");
        }
        unless (chdir("$Bin/../")) {
            $debug->write(DEBUG_ERROR, "Can't chdir(): $!");
            exit(-1);
        }
        unless (open(STDIN, '/dev/null')) {
            $debug->write(DEBUG_ERROR, "Can't open(): $!");
            exit(-1);
        }
        unless (open(STDOUT, '>/dev/null')) {
            $debug->write(DEBUG_ERROR, "Can't open(): $!");
            exit(-1);
        }
        unless (open(STDERR, '>&STDOUT')) {
            $debug->write(DEBUG_ERROR, "Can't open(): $!");
            exit(-1);
        }

        $new_pid = fork;

        if (! defined($new_pid)) {
            $debug->write(DEBUG_ERROR, "Can't fork(): $!");
            exit(-1);
        } elsif ($new_pid > 0) {
            $debug->write(
                DEBUG_DEBUG,
                "New child has borned with PID $new_pid"
            );
            exit(0);
        } else {
            unless (defined($debug->reopen)) {
                die("Can't debug->reopen(): $debug->{'error'}");
            }
            unless (setsid) {
                $debug->write(DEBUG_ERROR, "Can't setsid(): $!");
                exit(-1);
            }
        }
        
    }
}


# ������ ���� ���

$0 = "nanny.pl";


# ������������ � SQL

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

$debug->write(
    DEBUG_DEBUG, "Connecting to SQL-server at " . $conf->{'mysql_r_host'}
);
my $dbh_r = DBI->connect(
    "DBI:mysql:database=" . $conf->{'mysql_r_db'}.
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

# �������������� �������� SQL-���������� ��� ����������� �������

# ��������� ������ NAS'��
my $sth_get_nases = $dbh_c->prepare(
    "SELECT " .
        "nid, " .
        "naddr, " .
        "ncomm, " .
        "nsrac, " .
        "nntbc, " .
        "ntype, " .
        "nports " .
    "FROM nases"
);

# ��������� ������ �������� �� ������ ������ ������ � ���� RADIUS
my $sth_r_get_opened_sessions = $dbh_r->prepare(
    "SELECT " .
        "AcctUniqueId, " .
        "UserName, " .
        "NASIPAddress, " .
        "NASPortId, " .
        "NASPortType, " .
        "AcctStartTime, " .
        "CallingStationId, " .
        "CalledStationId " .
    "FROM radacct " .
    "WHERE " .
#        "AcctStartTime >= ? AND " .
        "AcctStopTime = '0000-00-00 00:00:00' " .
    "ORDER BY " .
        "AcctStartTime"
);

# ��������� ������ �������� �� ������ ������ ������ � ���� Catty
my $sth_c_get_opened_sessions = $dbh_c->prepare(
    "SELECT " . 
        "sessions.ssession, " .
        "users.ulogin, " .
        "nases.naddr, " .
        "sessions.snasport, " .
        "sessions.stime_start, " .
        "sessions.stime_stop " .
    "FROM sessions, users, nases " .
    "WHERE " .
        "sessions.stime_stop = '0000-00-00 00:00:00' AND " .
        "sessions.suser = users.uid AND " .
        "sessions.snas = nases.nid"
);

# �������� "���������" ������ � ���� RADIUS
my $sth_r_close_stalled_session = $dbh_r->prepare(
    "UPDATE radacct " .
    "SET AcctStopTime = NOW() " .
    "WHERE " .
        "AcctUniqueId = ? AND " .
        "AcctStopTime = '0000-00-00 00:00:00'"
);

# �������� "���������" ������ � ���� Catty
my $sth_c_close_stalled_session = $dbh_c->prepare(
    "UPDATE sessions " .
    "SET stime_stop = NOW() " .
    "WHERE " .
        "ssession = ? AND " .
        "stime_stop = '0000-00-00 00:00:00'"
);


# ���������� ������ ����������

my $time_now;   # ������� �������� �������
my $time_was;   # �������� ������� ��� ���������� ��������
my $time_start; # �������� ������� ��� ������ ������������

my %sessions;   # ��� ������, ��� ���� - id ������, ��������� - ������
my %nases;      # ��� NAS'��, ��� ���� - ����� NAS, �������� - ������
my %users;      # ��� �������������, ��� ���� - �����-���, �������� - ������

my $stop_job;   # ��� ������ ������ TRUE - ������������� ������


# �������� ������� NAS'�� � ������ NAS-��������

$debug->write(DEBUG_DEBUG, "Initializing NAS-monitors");
unless (defined($sth_get_nases->execute)) {
    $debug->write(DEBUG_ERROR, "Can't DBI::st->execute(): " . $dbh_c->errstr);
    exit(-1);
}
while (
    my (
        $db_nid,        # ������������� ������ � NAS
        $db_naddr,      # IP-����� NAS
        $db_ncomm,      # RW-���������� (SNMP) NAS
        $db_nsrac,      # S.upports R.adius AC.counting
        $db_nntbc,      # N.eed T.o B.e C.hecked
        $db_ntype,      # ��� NAS
        $db_nports      # ���������� ������
    ) = $sth_get_nases->fetchrow_array
) {

    # ��� ������� NAS �������������� ������ ������ catty::nas

    my $db_ncomm_secret = $db_ncomm; $db_ncomm_secret =~ s/./*/g;
    $debug->write(
        DEBUG_DEBUG,
        "Found NAS $db_nid:$db_naddr:$db_ncomm_secret"
    );
    my ($nas_object, $nas_error) = catty::nas->new(
        -nid        => $db_nid,
        -naddr      => $db_naddr,
        -ncomm      => $db_ncomm,
        -nsrac      => $db_nsrac,
        -nntbc      => $db_nntbc,
        -ntype      => $db_ntype,
        -nports     => $db_nports
    );
    unless (defined($nas_object)) {
        $debug->write(
            DEBUG_ERROR,
            "Can't catty::nas->new(): $nas_error"
        );
        exit(-1);
    }
    $nases{$db_naddr} = $nas_object;
}
unless (defined($sth_get_nases->finish)) {
    $debug->write(DEBUG_ERROR, "Can't DBI::st->finish(): " . $dbh_c->errstr);
    exit(-1);
}


# ������� "������" ����, �� ����� ����������� �������

$SIG{'HUP'}     = \&sig_reload;
$SIG{'INT'}     = \&sig_fatal;
$SIG{'QUIT'}    = \&sig_fatal;
$SIG{'TRAP'}    = \&sig_fatal;
$SIG{'IOT'}     = \&sig_fatal;
$SIG{'TERM'}    = \&sig_fatal;
$SIG{'FPE'}     = \&sig_fatal;
$SIG{'SEGV'}    = \&sig_fatal;
$SIG{'ILL'}     = \&sig_fatal;
$SIG{'USR1'}    = \&sig_empty;

# ��������� PID-����

if (-r $conf->{'pid_file'}) {
    if ((stat($conf->{'pid_file'}))[9] < (time - $conf->{'step'} * 30)) {
        $debug->write(DEBUG_WARNING, "PID-file found, but seems to be stalled");
    } else {
        $debug->write(DEBUG_ERROR, "PID-file found, can't run");
        exit(-1);
    }
}


# ������ ���������� ������������ ���:)

my @to_sleep = ($conf->{'step'} x 10);

do {

    # ������ ������...

    $debug->write(DEBUG_DEBUG, "*** Beginning new iteration ***");


    # ��������� PID-����
    
    unless (defined(write_pid($conf->{'pid_file'}))) {
        $debug->write(DEBUG_ERROR, "Can't write_pid()");
        last;
    }


    # ������� ���?

    $time_now = strftime("%Y-%m-%d %H:%M:%S", localtime);
    unless (defined($time_start)) {
        $time_start = $time_now;
    }

    $debug->write(
        DEBUG_DEBUG,
        "System clock shows: $time_now (" . timestamp2unixtime($time_now) . ")"
    );


    # ���� ��� ������ �������� � ����� ���������� ���������� �������� ��� ��
    # ��������������� � ������������� ����������, ���������� ��� ��������
    # ��������, � ������ ������ � ����� ��������

    unless (defined($time_was)) {
        $debug->write(
            DEBUG_DEBUG,
            "Whoa, hello, fucking world, I'm borned as $$!"
        );
        $time_was =
            unixtime2timestamp(timestamp2unixtime($time_now) - $conf->{'step'});
        $debug->write(
            DEBUG_DEBUG,
            "I will guess previous timestamp as $time_was (" .
            timestamp2unixtime($time_was) .
            ")"
        );
    }

    
    # ���� ���� �������� � ������� ����� ������� (�) ?


    # ��������� ������ �������� ������ �� ���� RADIUS

    $debug->write(
        DEBUG_DEBUG,
        "Getting list of currently opened sessions from SQL-server (radius db)"
    );

    unless (defined($sth_r_get_opened_sessions->execute())) {
        $debug->write(DEBUG_ERROR, "Can't DBI::st->execute(): " . $dbh_r->errstr);
        next;
    }

    while (
        my (
            $db_acctsessionid,
            $db_username,
            $db_nasipaddress,
            $db_nasportid,
            $db_nasporttype,
            $db_acctstarttime,
            $db_callingstationid,
            $db_calledstationid
        ) = $sth_r_get_opened_sessions->fetchrow_array
    ) {

        # ��� ������ ����� ������, ������� ��� ��� � ����, �� ��������������
        # ������ ������ catty::session �, ���� ����������, ��������������
        # ������ ������ catty::user ��� ������������

        unless (defined($sessions{$db_acctsessionid})) {

            # �������� ���������� ���� ���������� ���������� ������
    
            my $invalid = 0;
            unless (defined($db_acctsessionid)) {
                $invalid++;
                $debug->write(
                    DEBUG_WARNING,
                    "Undefined radacct:AcctUniqueId, what the fuck?!"
                );
            }
            unless (defined($db_username)) {
                $invalid++;
                $debug->write(
                    DEBUG_WARNING,
                    "Undefined radacct:UserName, what the fuck?!"
                );
            }
            unless (defined($db_nasipaddress)) {
                $invalid++;
                $debug->write(
                    DEBUG_WARNING,
                    "Undefined radacct:NASIPAddress, what the fuck?!"
                );
            }
            unless (defined($db_nasportid)) {
                $invalid++;
                $debug->write(
                    DEBUG_WARNING,
                    "Undefined radacct:NASPortId, what the fuck?!"
                );
            }
            unless (defined($db_nasporttype)) {
                $invalid++;
                $debug->write(
                    DEBUG_WARNING,
                    "Undefined radacct:NASPortType, what the fuck?!"
                );
            }

            $debug->write(
                DEBUG_INFO,
                "$db_acctsessionid: found " .
                "(" .
                    $db_username . ":" .
                    $db_nasipaddress . ":" .
                    $db_nasporttype. $db_nasportid .
                ")"
            );

            # ���� � ��� ��� ��� � ������ ������� ������ catty::user ��� �����
            # ������������, �������������� ����� ������ ��� ���������� ������

            unless (defined($users{$db_username})) {
                $debug->write(
                    DEBUG_DEBUG,
                    "Object for $db_username not found in memory, initializing"
                );
                
                my ($user_object, $user_error) =
                    catty::user->new(
                        -ulogin     => $db_username,
                        -dbh_c      => $dbh_c,
                        -dbh_r      => $dbh_r,
                        -ubalance_t => $db_acctstarttime
                    );
                if (defined($user_object)) {

                    # ��������� ������������ ������ � ���� �������� ����� ������
                    # ��� ����������� ��������
                    
                    $users{$db_username} = $user_object;
    
                    $debug->write(
                        DEBUG_DEBUG,
                        "User " .
                        $users{$db_username}->{'ulogin'} .
                        " initialized with uid " .
                        $users{$db_username}->{'uid'} .
                        " and package number " .
                        $users{$db_username}->{'upack'} .
                        " is applied"
                    );

                } else {
                    $invalid++;
                    $debug->write(
                        DEBUG_ERROR,
                        "Can't catty::user->new(): $user_error"
                    );
                }

            }

            unless (defined($users{$db_username})) {
                $invalid++;
                $debug->write(DEBUG_WARNING, "Unknown user '$db_username'");
            }
            unless (defined($nases{$db_nasipaddress})) {
                $invalid++;
                $debug->write(DEBUG_WARNING, "Unknown NAS '$db_nasipaddress'");
            }

            if ($invalid) {
                $debug->write(
                    DEBUG_WARNING,
                    "Could not create session object, too many errors (" .
                        $invalid .
                    ")"
                );
                close_session($db_acctsessionid);
                next;
            }

            # ������ ������ ������

            my ($session_object, $session_error) =
                catty::session->new(
                    -session        => $db_acctsessionid,
                    -user           => $users{$db_username},
                    -nas            => $nases{$db_nasipaddress},
                    -nasport        => $db_nasporttype . $db_nasportid,
                    -dbh_c          => $dbh_c,
                    -dbh_r          => $dbh_r,
                    -time_now       => $time_now,
                    -csid           => (
                        ($db_callingstationid eq '5381010') ?           #FIXME#
                            "$db_calledstationid+" :
                            "$db_callingstationid"
                    )
                );
            unless (defined($session_object)) {
                $debug->write(
                    DEBUG_ERROR,
                    "Can't catty::session->new(): $session_error"
                );
                close_session($db_acctsessionid);
                next;
            }

            # ������������� ������ ��������� � ���� �������� ������ � ��������
            # �����, � ��� ������ - � �������� �������� ��������

            $sessions{$db_acctsessionid} = $session_object;

            # ����� ��������� ���� ������������� � � ������� catty::user
            # ���������������� ������������...

            ${$users{$db_username}->{'usessions'}}{$db_acctsessionid} =
                $session_object;

            # ...� � ������� catty::nas ���������������� NAS

            ${$nases{$db_nasipaddress}->{'sessions'}}{$db_acctsessionid} =
                $session_object;

        }
    }

    unless (defined($sth_r_get_opened_sessions->finish)) {
        $debug->write(DEBUG_ERROR, "Can't DBI::st->finish(): " . $dbh_r->errstr);
        # exit(-1);
    }


    # ��������� ������ � ������ �� �������� ������ �� �������� �������
    
    $debug->write(DEBUG_DEBUG, "Refreshing active sessions (if any)");

    foreach my $session_id (
        sort (
            {
                timestamp2unixtime($sessions{$a}->{'time_start'}) cmp
                timestamp2unixtime($sessions{$b}->{'time_start'})
            }
                keys(%sessions)
        )
    ) {

        # ���������� RADIUS

        $debug->write(
            DEBUG_DEBUG,
            $sessions{$session_id}->{'session'} .
            ": refreshing (" .
            $sessions{$session_id}->{'user'}->{'ulogin'} . ":" .
            $sessions{$session_id}->{'nas'}->{'naddr'} . ":" .
            $sessions{$session_id}->{'nasport'} .
            ")"
        );

        unless (defined($sessions{$session_id}->query_radius($time_now))) {
            $debug->write(
                DEBUG_ERROR,
                "Can't catty::session->query_radius(): " .
                $sessions{$session_id}->{'error'}
            );
            seek_and_destroy($sessions{$session_id}->{'session'});
            next;
        }

        # ���������, �� ������ �� RADIUS � ��������� �� ��� �������� �
        # �������� ��������, ���� ���������� � NAS: � ������, ���� ��
        # ����������, ��� ������ �ӣ �ݣ �������, �� ��������� � NAS �
        # ������� ��� ���������� magic-�����, ������� _����_ ������
        # ����� ���������� ����� �������� ����� (��� ������ ����� �� �����),
        # ����� ����� ���������, ��������� �� �� � ���, ��� � ��� ��� ���� �
        # ������.

        if (
            ($sessions{$session_id}->{'nas'}->{'nntbc'}) &&
            (timestamp2unixtime($sessions{$session_id}->{'time_stop'}) <= 0)
        ) {
            my $magic_changed =
                $sessions{$session_id}->{'nas'}->check_magic(
                    $sessions{$session_id}->{'nasport'},
                    $sessions{$session_id}->{'nasmagic'}
                );
            if (! defined($magic_changed)) {
                $debug->write(
                    DEBUG_ERROR,
                    "Can't catty::nas->check_magic(): " .
                        $sessions{$session_id}->{'nas'}->{'error'}
                );
            } elsif (! $magic_changed) {
                $debug->write(
                    DEBUG_WARNING,
                    "Can't find the same session by magic-number " .
                        $sessions{$session_id}->{'nasmagic'}
                );
            } else {
                next;
            }
           
            close_session($sessions{$session_id}->{'session'});
            redo;
        }
    }


    # ��� ������ �� �������� ������ (�� ������ ���, ��� ���� ����������
    # ��������� ��� ���� ��������, � � ��� ���, ��� ��� �������� ��������� �
    # ������ ����������� �������!) ��������� �����������:
    #   1. ��������� ���������� �������, ����������� ��� �� ����� � �������
    #      ���������� ���������������� ����� (�� ��� ������ ����������,
    #      ��� ������������� ������ ������, � �����-������, �� ����� ��������
    #      �� ������� ���������� ������ � ��������� � ���������� ����������
    #      ������� ����� ���������� � ��� �������� �������� ������
    #      �����������, ����� �������������� ��� - ��� ��-�� ���� ���� ������
    #      �� �������� ��� �������, � �� ������ �� ����������� �����,
    #      ���������� ��� �� ��� (��� ����, ��� ��������!)
    #   2. ���������, ������� �������� �� ����� ������� ��� ��������,
    #      ����������� � ���� RADIUS �, ���� ��� ����� ������� ��������,
    #      ����������� � ���, ��� NAS �� ����� �������� �������������� ������
    #      � �������� ������, ������� ��� ������ � ���������� NAS, �� �������
    #      � ����� ������������...
    #      .*. ��������! .*.
    #      ���� ���� NAS ��� �� ������ ��� ������ �� RADIUS, �����������
    #      ��������� � ���, ��� ��� ���������� ����, ��� ��� ���������
    #      ��������� ������� �����������!
    #   3. ��������� ���������� �����, �� ������� "��������" ������������ ��
    #      ������ � ���������� ����� �������������� ������������, �������� �
    #      ��� �������� ������
    #   4. ���������, ����� �� ���������� ��� ������ ��� ����� ���� �������
    #      �� �� ���

    my $threshold_violators_killed = 0;

    $debug->write(DEBUG_DEBUG, "Accounting active sessions (if any)");

    foreach my $session_id (
        sort (
            {
                timestamp2unixtime($sessions{$a}->{'time_start'}) cmp
                timestamp2unixtime($sessions{$b}->{'time_start'})
            }
                keys(%sessions)
        )
    ) {

        $debug->write(
            DEBUG_DEBUG,
            $sessions{$session_id}->{'session'} .
            ": accounting (" .
            $sessions{$session_id}->{'user'}->{'ulogin'} . ":" .
            $sessions{$session_id}->{'nas'}->{'naddr'} . ":" .
            $sessions{$session_id}->{'nasport'} .
            ")"
        );


        # ������� ������� ������� ���� �������?

        $debug->write(
            DEBUG_DEBUG,
            $sessions{$session_id}->{'session'} . ": counting time"
        );

        unless (
            defined($sessions{$session_id}->count_time($time_now, $time_was))
        ) {
            $debug->write(
                DEBUG_ERROR,
                "Can't catty::session->count_time(): " .
                $sessions{$session_id}->{'error'}
            );
            seek_and_destroy($sessions{$session_id}->{'session'});
            next;
        }

        if ($sessions{$session_id}->{'time_used'} < 0) {
            $debug->write(
                DEBUG_ERROR,
                "catty::session->count_time() made a negative value: " .
                $sessions{$session_id}->{'time_used'}
            );
            seek_and_destroy($sessions{$session_id}->{'session'});
            next;
        }

        $debug->write(
            DEBUG_DEBUG,
            $sessions{$session_id}->{'session'} .
            ": is online for " .
            $sessions{$session_id}->{'time_used'} .
            " seconds"
        );


        # ������� ������� �� ����� ��������?

        $debug->write(
            DEBUG_DEBUG,
            $sessions{$session_id}->{'session'} . ": counting traffic"
        );

        unless (defined($sessions{$session_id}->count_traffic($time_now))) {
            $debug->write(
                DEBUG_ERROR,
                "Can't catty::session->count_traffic(): " .
                $sessions{$session_id}->{'error'}
            );
            seek_and_destroy($sessions{$session_id}->{'session'});
            next;
        }

        $debug->write(
            DEBUG_DEBUG,
            $sessions{$session_id}->{'session'} .
            ": received " .
            $sessions{$session_id}->{'traf_input'} . " octets" .
            " and transmitted " .
            $sessions{$session_id}->{'traf_output'} . " octets"
        );


        # ������������, ������� ������ �� ��� ������

        $debug->write(
            DEBUG_DEBUG,
            $sessions{$session_id}->{'session'} . ": counting cost"
        );

        unless (
            defined($sessions{$session_id}->count_cost($time_now))
        ) {
            $debug->write(
                DEBUG_ERROR,
                "Can't catty::session->count_cost(): " .
                $sessions{$session_id}->{'error'}
            );
            seek_and_destroy($sessions{$session_id}->{'session'});
            next;
        }

        $debug->write(
            DEBUG_DEBUG,
            "$sessions{$session_id}->{'session'}: has used " .
            "$sessions{$session_id}->{'cost'} units"
        );

        
        # ���� ��������� ������ < 0, ��� ��������, ��� ������ ��������!
        # � ��������� ������ �� ��������� ��� ������ � ������� ������������

        $debug->write(
            DEBUG_DEBUG,
            "$sessions{$session_id}->{'session'}: checking for access grants"
        );

        if ($sessions{$session_id}->{'cost'} < 0) {
            $debug->write(
                DEBUG_DEBUG,
                $sessions{$session_id}->{'session'} . ": access denied!"
            );
            # ���� �� ������������ �������-��:)
            $sessions{$session_id}->{'cost'} = 0;
            # ������� ����� �� �����:)
            seek_and_destroy($sessions{$session_id}->{'session'});
            next;
        }

        # �� ���� ��������� ��������������� ����������� �����������.

        # ��������� ������ ������������, ������� �������� � ���� ������, �
        # ��� user::session->{'uexpire'}
        # ������, ���! ���� � ����� catty::user->{'udbtr'} ���������� TRUE �
        # ��� ���� catty::user->{'udbtrd'} �� ���� ������� ����-�������, ��
        # ���� ���� ����� ����� �������� � ������ � �������� � ���� ��� ������
        # � ����� �� �����, ���� �� ��������� user::session->{'uexpire'},
        # ������ ������� �� ���� � ��������� �������:)

        $debug->write(
            DEBUG_DEBUG,
            $sessions{$session_id}->{'session'} .
            ": checking balance and expiration date"
        );

        my $user_balance = $sessions{$session_id}->{'user'}->check_balance(
            $sessions{$session_id}->{'session'},
            $time_now
        );

        unless (defined($user_balance)) {
            $debug->write(
                DEBUG_ERROR,
                "Can't catty::user->check_balance(): " .
                $sessions{$session_id}->{'user'}->{'error'}
            );
            seek_and_destroy($sessions{$session_id}->{'session'});
            next;
        }

        $debug->write(
            DEBUG_DEBUG,
            $sessions{$session_id}->{'session'} .
            ": balance for user " .
            $sessions{$session_id}->{'user'}->{'ulogin'} .
            " is " .
            $user_balance .
            " (" .
            $sessions{$session_id}->{'user'}->{'ubalance_c'} .
            "(" .
            $sessions{$session_id}->{'user'}->{'ubalance_t'} .
            ")" .
            $sessions{$session_id}->{'user'}->{'ubalance_n'} .
            ")"
        );

        $debug->write(
            DEBUG_DEBUG,
            $sessions{$session_id}->{'session'} .
            ": account of user " .
            $sessions{$session_id}->{'user'}->{'ulogin'} .
            " will be expired on " .
            $sessions{$session_id}->{'user'}->{'uexpire'}
        );


        # �������� �� ����! ���� RADIUS ����������, ��� ������ ��� �������,
        # ��������� ����������� ��� �� �����������

        if (timestamp2unixtime($sessions{$session_id}->{'time_stop'}) > 0) {
            $debug->write(
                DEBUG_DEBUG,
                $sessions{$session_id}->{'session'} .
                ": session is down, skipping"
            );
            next;
        }

        # ��, � ���� �� �ݣ �����, ��������, �� ������� �� ��� ���-������ ��
        # ��������� ������

        # ��������� ������

        if (
            ($sessions{$session_id}->{'user'}->{'ubalance'} <= 0) &&
            (! (
                ($sessions{$session_id}->{'user'}->{'udbtr'}) &&
                (
                    timestamp2unixtime($sessions{$session_id}->{'user'}->{'udbtrd'}) >
                    timestamp2unixtime($time_now)
                )
            ))
        ) {
            $debug->write(DEBUG_INFO, "Balance is negative or zero!");
            seek_and_destroy($sessions{$session_id}->{'session'});
            next;
        }

        # ���������, �� ������������� �� �������

        if (
            timestamp2unixtime($sessions{$session_id}->{'user'}->{'uexpire'}) <
            timestamp2unixtime($time_now)
        ) {
            $debug->write(DEBUG_INFO, "Account is expired!");
            seek_and_destroy($sessions{$session_id}->{'session'});
            next;
        }

        # ���������, �� ������� �� ����� ������������� ����������

        if (
            $sessions{$session_id}->{'user'}->{'uklogins'} <
            scalar(keys(%{$sessions{$session_id}->{'user'}->{'usessions'}}))
        ) {
            $debug->write(DEBUG_INFO, "Too many simultaneous sessions!");
            seek_and_destroy($sessions{$session_id}->{'session'});
            next;
        }

        # ���������, �� ���� �� ��������� ����-�� �� "�����������������"

        if (
            ($threshold_violators_killed < 3) &&
            ($sessions{$session_id}->{'user'}->{'ukthreshold'} > 0) &&
            (
                $sessions{$session_id}->{'nas'}->{'nports'} -
                scalar(keys(%{$sessions{$session_id}->{'nas'}->{'sessions'}}))
            ) <= $sessions{$session_id}->{'user'}->{'ukthreshold'}
        ) {
            $debug->write(DEBUG_INFO, "Threshold reached for this user");
            seek_and_destroy($sessions{$session_id}->{'session'});
            $threshold_violators_killed++;
            next;
        }

        # ���������, ��� ��, ���� ����������, ������������ ���������� �������

        if (
            ($sessions{$session_id}->{'user'}->{'ukmute'} > 0 ) &&
            (
                (
                    (defined($sessions{$session_id}->{'advertized'})) &&
                    (
                        timestamp2unixtime($time_now) -
                        timestamp2unixtime($sessions{$session_id}->{'advertized'})
                    ) >= $sessions{$session_id}->{'user'}->{'ukmute'}
                ) || (
                    (defined($sessions{$session_id}->{'advertized'})) &&
                    (
                        timestamp2unixtime($time_now) -
                        timestamp2unixtime($sessions{$session_id}->{'time_start'})
                    ) >= $sessions{$session_id}->{'user'}->{'ukmute'}
                )
            )
        ) {
            $debug->write(DEBUG_INFO, "Did not receive advertizing");
            seek_and_destroy($sessions{$session_id}->{'session'});
            next;
        }

        # ���������, �� ��������� �� ����������� �� ����������������� ������

        if (
            ($sessions{$session_id}->{'user'}->{'uslimit'} > 0) &&
            (
                timestamp2unixtime($time_now) -
                timestamp2unixtime($sessions{$session_id}->{'time_start'})
            ) >= ($sessions{$session_id}->{'user'}->{'uslimit'} * 60)
        ) {
            $debug->write(DEBUG_INFO, "Time limit exceeded for this session");
            seek_and_destroy($sessions{$session_id}->{'session'});
            next;
        }

    }


    # ��� ������ �� �������� ������ �������� ������ ����������� ����������

    $debug->write(DEBUG_DEBUG, "Writing accounting data of active sessions (if any)");

    foreach my $session_id (
        sort (
            {
                timestamp2unixtime($sessions{$a}->{'time_start'}) cmp
                timestamp2unixtime($sessions{$b}->{'time_start'})
            }
                keys(%sessions)
        )
    ) {

        $debug->write(
            DEBUG_DEBUG,
            $sessions{$session_id}->{'session'} .
            ": writing accounting data for " .
            $sessions{$session_id}->{'user'}->{'ulogin'}
        );

        unless (
            defined($sessions{$session_id}->write_acctdata(
                $sessions{$session_id}->{'cost'}
            ))
        ) {
            $debug->write(
                DEBUG_ERROR,
                "Can't catty::session->write_acctdata(): " .
                $sessions{$session_id}->{'error'}
            );
            seek_and_destroy($sessions{$session_id}->{'session'});
            next;
        }
    
    }


    # ��� ������ �� �������� ������ ��������, �� ����� �� �� ������ �� �����

    $debug->write(DEBUG_DEBUG, "Checking status of active sessions (if any)");

    foreach my $session_id (
        sort (
            {
                timestamp2unixtime($sessions{$a}->{'time_start'}) cmp
                timestamp2unixtime($sessions{$b}->{'time_start'})
            }
                keys(%sessions)
        )
    ) {

        $debug->write(
            DEBUG_DEBUG,
            $sessions{$session_id}->{'session'} .
            ": checking (" .
            $sessions{$session_id}->{'user'}->{'ulogin'} . ":" .
            $sessions{$session_id}->{'nas'}->{'naddr'} . ":" .
            $sessions{$session_id}->{'nasport'} .
            ")"
        );
    
        if (timestamp2unixtime($sessions{$session_id}->{'time_stop'}) > 0) {

            $debug->write(
                DEBUG_INFO,
                $sessions{$session_id}->{'session'} .
                ": session has been poshla po pizde and will be closed (" .
                $sessions{$session_id}->{'user'}->{'ulogin'} . ":" .
                $sessions{$session_id}->{'nas'}->{'naddr'} . ":" .
                $sessions{$session_id}->{'nasport'} .
                ")"
            );

            # ���������� ������� �������� ���������� ������ ����� �������,
            # ���� �� ��� ����� ��� �� ������ ��� ����������� ������� � ������.
            # ���� � �������� �������� ���������� �����-���� ���������, ������,
            # ��� �� ��� � ������� � ������� �����������

            unless (defined($sessions{$session_id}->close)) {
                $debug->write(
                    DEBUG_ERROR,
                    "Can't catty::session->close(): " .
                    $sessions{$session_id}->{'error'}
                );
                # exit(-1);
            }

            # ��ޣ������� ������ �� ������ �� ������� catty::user...

            delete(${$sessions{$session_id}->{'user'}->{'usessions'}}{$session_id});

            # ...� �� ������� catty::nas

            delete(${$sessions{$session_id}->{'nas'}->{'sessions'}}{$session_id});

            # ������� ������ catty::session �� ������; �� ��� ������ ��
            # �����������

            $sessions{$session_id}->DESTROY;

            # ����������� �� ����
            
            delete($sessions{$session_id});
        }

    }


    # �������� �� ���� ������ �� ������, ��� ������� �� ������� �� ����� ������
    # ���� ������ ������������ �� perl, ������ ������ catty::user ����� ������
    # �� ������ ���������, ��� ������ �������� ��� ������ �� ����

    $debug->write(DEBUG_DEBUG, "Checking status of cached users (if any)");
    foreach my $user (keys(%users)) {
        unless (scalar(keys(%{$users{$user}->{'usessions'}}))) {
            $debug->write(
                DEBUG_DEBUG,
                "User $users{$user}->{'ulogin'} will be removed from cache"
            );
            delete($users{$user});
        }
    }


    # �������� ������ �������� ������ �� ���� catty, ����� ���������� ��
    # ���������� :)

    $debug->write(
        DEBUG_DEBUG,
        "Getting list of currently opened sessions from SQL-server (catty db)"
    );

    unless (defined($sth_c_get_opened_sessions->execute())) {
        $debug->write(DEBUG_ERROR, "Can't DBI::st->execute(): " . $dbh_c->errstr);
        next;
    }

    while (
        my (
            $db_ssession,
            $db_ulogin,
            $db_naddr,
            $db_snasport,
            $db_stime_start,
            $db_stime_stop
        ) = $sth_c_get_opened_sessions->fetchrow_array
    ) {
        unless (defined($sessions{$db_ssession})) {
            $debug->write(
                DEBUG_WARNING,
                "Found stalled session in database: " .
                "$db_ssession:$db_ulogin:$db_naddr:$db_snasport " .
                "($db_stime_start - $db_stime_stop)"
            );
            $debug->write(DEBUG_INFO, "Closing stalled session $db_ssession");
            my $rows_affected =
                $sth_c_close_stalled_session->execute($db_ssession);
            if (! defined($rows_affected)) {
                $debug->write(
                    DEBUG_ERROR,
                    "Can't DBI::st->execute(): " . $dbh_c->errstr
                );
                return(undef);
            } elsif ($rows_affected != 1) {
                $debug->write(
                    DEBUG_WARNING,
                    "Strange behavior, " .
                    "$rows_affected rows affected in sessions-table"
                )
            }
        }
    }

    unless (defined($sth_c_get_opened_sessions->finish)) {
        $debug->write(DEBUG_ERROR, "Can't DBI::st->finish(): " . $dbh_c->errstr);
        # exit(-1);
    }


    # ����� �� ��������� �� �������, ���� ����� �������, ������� ����������
    # ��� ����, ���� �������������� ���� ���������� �� ���������� �������.

    my $to_sleep_sum;
    my $latency =
        timestamp2unixtime($time_now) - timestamp2unixtime($time_was);
    for my $to_sleep_val (@to_sleep) {
        $to_sleep_sum = ($to_sleep_sum + $to_sleep_val) / 2
    }
    my $to_sleep_new    = (((2 * $conf->{'step'}) - $latency) + $to_sleep_sum) / 2;
    $to_sleep_new       = $conf->{'step'} if ($to_sleep_new > $conf->{'step'});
    $to_sleep_new       = 0               if ($to_sleep_new < 0);
    pop(@to_sleep); unshift(@to_sleep, $to_sleep_new);

    $debug->write(
        DEBUG_DEBUG,
        "Sleeping for $to_sleep_new seconds, latency is $latency"
    );

    sleep($to_sleep_new);
            
    # ������, ����� ����������� ������ �� ������� ��������� � ����� ��
    # �������� ����������� ���������� �������, �� ����� ��������� ��������
    # ����-����� ����� ������� ����� ��������, � ����� ������ ������� �� �����
    # ������� �� ����� ����������

    $time_was = $time_now;


# ��� � ����� �����, � ��� ������� - �������
# � ��� �� ������� - ������� �������� �����!

} until ($stop_job);

# ����� ���� ������� ���������� � ����� ������...

foreach my $session_id (
    sort (
        {
            timestamp2unixtime($sessions{$a}->{'time_start'}) cmp
            timestamp2unixtime($sessions{$b}->{'time_start'})
        }
            keys(%sessions)
    )
) {
    $debug->write(
        DEBUG_DEBUG,
        "Closing session $session_id"
    );
    unless (defined($sessions{$session_id}->close)) {
        $debug->write(
            DEBUG_ERROR,
            "Can't catty::session->close(): " .
            $sessions{$session_id}->{'error'}
        );
    }
}

# ������� PID-����

$debug->write(DEBUG_DEBUG, "Removing a PID-file");
unless (defined(unlink($conf->{'pid_file'}))) {
    $debug->write(DEBUG_DEBUG, "Can't unlink(): $!");
    # exit(-1);
}

# ��������� NAS-���������

$debug->write(DEBUG_DEBUG, "Shutting SNMP-monitors down");
foreach my $nas (keys(%nases)) {
    unless (defined($nases{$nas}->close)) {
        $debug->write(
            DEBUG_ERROR,
            "Can't catty::nas->close(): " . $nases{$nas}->{'error'}
        );
        # exit(-1);
    }

    delete($nases{$nas});       # ������� ������ �� NAS �� ������
}


# ���������� �� SQL-�������

$debug->write(
    DEBUG_DEBUG,
    "Disconnecting from MySQL-server at " . $conf->{'mysql_c_host'}
);
unless (defined($dbh_c->disconnect)) {
    $debug->write(DEBUG_ERROR, "Can't DBI::db->close(): " . $dbh_c->errstr);
}

$debug->write(
    DEBUG_DEBUG, "Disconnecting from MySQL-server at " .
    $conf->{'mysql_r_host'}
);
unless (defined($dbh_r->disconnect)) {
    $debug->write(DEBUG_ERROR, "Can't DBI::db->close(): " . $dbh_r->errstr);
}


# �������� ���������� ����������������

$debug->write(
    DEBUG_DEBUG, "My last words before I will close logs"
);
unless (defined($debug->close)) {
    warn("Can't debug->close(): $debug->{'error'}");
    # exit(-1);
}


# �� ������� � ������ ��������!

exit(my $consience = undef);


# ������������ ��������

sub sig_fatal {
    my $signal = shift;

    $debug->write(DEBUG_INFO, "Caught SIG$signal (fatal), terminating job");

    $stop_job = 1;
}

sub sig_reload {
    my $signal = shift;

    $debug->write(DEBUG_INFO, "Caught SIG$signal (reload), reopening log-file");

    unless (defined($debug->reopen)) {
        die("Can't debug->reopen(): $debug->{'error'}");
    }
}


sub sig_empty {
    my $signal = shift;

    $debug->write(DEBUG_INFO, "Caught SIG$signal (empty), stop sleeping! :)");
}


# ������� �������� � ������ PID-�����

sub write_pid {
    my ($pid_file) = @_;
    unless (defined($pid_file)) {
        $debug->write(DEBUG_ERROR, "Undefined name of PID-file");
        return(undef)
    }

    $debug->write(DEBUG_DEBUG, "Creating a PID-file");
    unless (defined(open(PID_FILE, ">$pid_file"))) {
        $debug->write(DEBUG_ERROR, "Can't open(): $!");
        return(undef);
    }

    print(PID_FILE $$);
    unless (defined(close(PID_FILE))) {
        $debug->write(DEBUG_WARNING, "Can't close(): $!");
    }

    return(0);
}


# ������� ��������������� �������� ������ � ���� radacct

sub close_session {
    my $session = shift;
    unless (defined($session)) {
        $debug->write(DEBUG_ERROR, "Undefined session number to close");
        return(undef);
    }

    $debug->write(DEBUG_INFO, "Closing stalled session $session");
    my $rows_affected = $sth_r_close_stalled_session->execute($session);
    if (! defined($rows_affected)) {
        $debug->write(
            DEBUG_ERROR,
            "Can't DBI::st->execute(): " . $dbh_r->errstr
        );
        return(undef);
    } elsif ($rows_affected != 1) {
        $debug->write(
            DEBUG_WARNING,
            "Strange behavior, $rows_affected rows affected in radacct-table"
        )
    }
    
    return($session);
}

# �������-�������-�������� �-��� ������ ����������
# ...��, �����, �������� ��� ������ ������... :-//

sub seek_and_destroy {
    my $session = shift;

    unless (defined($session)) {
        $debug->write(
            DEBUG_ERROR,
            "Undefined session number to seek and destroy"
        );
        return(undef);
    }

    $debug->write(DEBUG_INFO, "Terminating session $session");

    unless (defined($sessions{$session}->{'nas'}->terminate(
        $sessions{$session}->{'nasport'}
    ))) {
        $debug->write(
            DEBUG_ERROR,
            "Can't catty::nas->terminate(): " .
                $sessions{$session}->{'nas'}->{'error'}
        );
        return(undef);
    }

#    my $cli = RPC::XML::Client->new(
#        'http://' . $conf->{'xmlrpc_host'} .
#        ':'       . $conf->{'xmlrpc_port'} .
#        '/'       . $conf->{'xmlrpc_path'}
#    );
#    my $req = RPC::XML::request->new('catty.kill', {
#        login       => $conf->{'xmlrpc_adm_login'},
#        passwd      => $conf->{'xmlrpc_adm_passwd'}
#    }, {
#        ssession    => $session
#    });
#    my $res = $cli->send_request($req);
#    unless (ref($res)) {
#        $debug->write(
#            DEBUG_ERROR, "Can't RPC::XML::Client->send_request(): $res"
#        );
#        return(undef);
#    }
#    if ($res->is_fault) {
#        $debug->write(
#            DEBUG_ERROR,
#            "Can't catty.kill(): " . $res->value->{'faultString'} . " " .
#            "(" . $res->value->{'faultCode'} . ")"
#        );
#        return(undef)
#    }
#    return(1);
    
#
#    my $new_pid = open(KID, "-|");
#
#    if (! defined($new_pid)) {
#        $debug->write(DEBUG_ERROR, "Can't fork(): $!");
#        return(undef);
#    } elsif ($new_pid > 0) {
#        while(<KID>) {
#            chomp;
#            $debug->write(DEBUG_DEBUG, "KILLER: $_");
#        }
#        return(0);
#    } else {
#        unless (open(STDERR, '>&STDOUT')) {
#            warn("Can't open(): $!");
#            exit(-1);
#        }
#
#        my @killer = split(/ /, $conf->{'ckill'});
#        for (@killer) {
#            s/([^\%])?\%s/$1$session/g;
#            s/\%\%/\%/g;
#        };
#
#        unless (exec(@killer)) {
#            warn("Can't exec(): $!");
#            exit(-1);
#        }
#
#        exit;
#    }

    return(0);

}
