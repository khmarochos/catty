#!/usr/bin/perl
#
#   $Id$
#
#   notify.pl, assistance module which sends notifications
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

# ������ ������

use catty::config qw(
    :CATTY_main
);
use catty::configure::notify;
use catty::user;

# ���������� ������

use debug qw(:debug_levels);
use timestamp;

# ���������� "�����"

use Getopt::Std;
use DBI;
use POSIX qw(strftime);


# �������� ���������������� ������

my $conf = catty::configure::notify->new;
unless (defined($conf)) {
    exit(-1);
}


# ��������� ��������� ���������������� 

my ($debug, $debug_error) = debug->new(
    debug_level_logfile => $conf->{'log_level'},
    debug_level_stdout  => DEBUG_INFO,
    debug_level_stderr  => DEBUG_WARNING,
    logfile             => $conf->{'log_file'}
);
unless (defined($debug)) {
    die("Can't debug->new(): $debug_error");
}
unless (defined($debug->reopen)) {
    die("Can't debug->reopen(): $debug->{'error'}");
}


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


# ������� ���?

my $time_now = strftime("%Y-%m-%d %H:%M:%S", localtime);
$debug->write(
    DEBUG_DEBUG,
    "System clock shows: $time_now (" . timestamp2unixtime($time_now) . ")"
);


# �������� ������ ���� ������������� � ���� ������, ���� ��� ������� �����
# �� �������� ��� �� ����������� ����� ��� ������ ����� -u, � ���� ���
# ���������� � ���-�� ������̣����, ���������� ����� � ���� ������ ���.

my @users_to_check;
my $sth_get_users;
if (defined($conf->{'username'})) {
    $debug->write(
        DEBUG_DEBUG,
        "Looking for user " . $conf->{'username'} . " in database"
    );
    $sth_get_users = $dbh_c->prepare(
        "SELECT ulogin " .
        "FROM " . 
            "users, " .
            "managers " .
        "WHERE " .
            "users.ulogin = ? AND " .
            "users.ulevel <= managers.mlevel AND " .
            "managers.mlogin = ? AND " .
            "managers.mactive != 0"
    );
} else {
    $debug->write(
        DEBUG_DEBUG,
        "Getting list of users in database"
    );
    $sth_get_users = $dbh_c->prepare(
        "SELECT ulogin " .
        "FROM " . 
            "users, " .
            "managers " .
        "WHERE " .
            "? IS NULL AND " .
            "ulogin NOT REGEXP '^[0-9]{14}\$' AND " .
            "ulogin NOT REGEXP '^[0-9]{7}\$' AND " .
            "ulogin NOT LIKE 'test%' AND " .
            "ulogin NOT LIKE '38067%' AND " .
            "ulogin NOT LIKE '38097%' AND " .
            "ulogin NOT LIKE '38050%' AND " .
            "ulogin NOT LIKE '38066%' AND " .
            "users.ulevel <= managers.mlevel AND " .
            "managers.mlogin = ?"
    );
}
unless (defined($sth_get_users->execute(
    $conf->{'username'},
    $conf->{'manager'}
))) {
    $debug->write(DEBUG_ERROR, "Can't DBI::st->execute(): " . $dbh_c->errstr);
    exit(-1);
}
while (my ($db_ulogin) = $sth_get_users->fetchrow_array) {
    $debug->write(DEBUG_DEBUG, "Got user $db_ulogin, creating object");
    my ($user, $user_error) = catty::user->new(
        -ulogin     => $db_ulogin,
        -dbh_c      => $dbh_c,
        -dbh_r      => $dbh_r,
        -ubalance_t => $time_now
    );
    unless (defined($user)) {
        $debug->write(DEBUG_ERROR, "Can't catty::user->new(): $user_error");
        next;
    }
    push(@users_to_check, $user);
}
unless (defined($sth_get_users->finish)) {
    $debug->write(DEBUG_ERROR, "Can't DBI::st->finish(): " . $dbh_c->errstr);
    exit(-1);
}


# ���� �� ������ �� �����, ������ ��� ����� ������ ����������:)

unless (scalar(@users_to_check)) {
    $debug->write(DEBUG_INFO, "No users found");
    exit;
}


# ������������ �������������

for my $user (@users_to_check) {

    # �������� ������� ������������

    $debug->write(
        DEBUG_DEBUG, "Calculating balance for user " . $user->{'ulogin'}
    );
    unless (defined($user->check_balance(undef, $time_now))) {
        $debug->write(
            DEBUG_ERROR,
            "Can't catty::user->check_balance(): " . $user->{'error'}
        );
        next;
    }

    # ���������� �� �������� ��������������?

    my $warning_text;
    my $need_to_warn = 1 if (
        (
            (
                # ���� ��� �ޣ� ��� ������...
                (
                    timestamp2unixtime($user->{'uexpire'}) <=
                    timestamp2unixtime($time_now)
                ) && (
                    $warning_text =
                        "���� �������� ������ �ޣ�� ��ԣ�"
                )
            ) || (
                # ���� ��� �ޣ� ����� ������ � ������� ��������� ���� ����...
                (
                    timestamp2unixtime($user->{'uexpire'}) -
                    timestamp2unixtime($time_now) <=
                        (86400 * 5)
                ) && (
                    $warning_text =
                        "���� �������� ������ �ޣ�� �������� " .
                        $user->{'uexpire'}
                )
            ) || (
                # ���� ��� ��������� ������������ � ��� ������ ��� ���� ���
                # ����� 2-� ��������...
                (
                    ($user->{'uktid'} == 1) &&
                    ($user->{'ubalance'} < 2)
                ) && (
                    $warning_text =
                        "� ��� �� ����� �������� \$" . $user->{'ubalance'}
                )
            ) || (
                # ���� ��� �������� ��� ������� ������������ � ���� ���������
                # �������� ��� ������� ��� ��������
                (
                    (($user->{'uktid'} == 2) || ($user->{'uktid'} == 3)) &&
                    (
                        (
                            timestamp2unixtime($user->{'ulpexpire'}) <=
                            timestamp2unixtime($time_now)
                        )
                    )
                ) && (
                    $warning_text =
                        "���� �������� ����� ������ ��ԣ�"
                )
            ) || (
                # ���� ��� �������� ��� ������� ������������ � ���� ���������
                # �������� ��� ������� �ݣ �� ��������, �� ����� ����� �������
                # � ������� ��������� ���� ����...
                (
                    (($user->{'uktid'} == 2) || ($user->{'uktid'} == 3)) &&
                    (
                        timestamp2unixtime($user->{'ulpexpire'}) -
                        timestamp2unixtime($time_now) <=
                            (86400 * 5)
                    )
                ) && (
                    $warning_text =
                        "���� �������� ����� ������ �������� " .
                        $user->{'ulpexpire'}
                )
            )
        ) && (
            # ���� ��� �ӣ� ��� ���� �� �������� ����� �� ���� �� ���� ��
            # ���������� ��� �����������...
            timestamp2unixtime($time_now) -
            timestamp2unixtime($user->{'unotified'}) >=
                (86400 * 1)
        ) && (
            # � ��� ���� �� �ݣ �� �������� ���� �����������...
            $user->{'unotifiedc'} < 5
        )
    );

    # �������� ����������� ������������, ���� ��� ����������
    if ($need_to_warn) {
        $debug->write(
            DEBUG_INFO, "User " . $user->{'ulogin'} . " needs to be warned"
        );
        my $new_pid = open(SENDMAIL, '|-');

        if (! defined($new_pid)) {
            $debug->write(DEBUG_ERROR, "Can't fork(): $!");
            next;
        } elsif ($new_pid > 0) {

            my $ulogin = $user->{'ulogin'};
            my $ukname = $user->{'ukname'};
            my $unotifyemail = $user->{'unotifyemail'};
            
            print(SENDMAIL
                "From: ���ޣ���� ����� SilverCom <billing\@silvercom.net>\n" .
                "To: $ulogin <$ulogin\@silvercom.net>\n" .
                "Cc: \"���ޣ���� ����� SilverCom\" <billing\@silvercom.net>" . (
                    ($user->{'unotifiedc'} == 4) ?
                        ", \"����� ������ SilverCom\" <sales-duty\@silvercom.net>" :
                        undef
                ) . (
                    (length($unotifyemail)) ?
                        ", <$unotifyemail>" :
                        undef
                ) . "\n" .
                "Subject: �������������� ��� $ulogin, ����������� ��������� ��� �ޣ�\n" .
                "Content-type: text/plain; charset=koi8-r\n" .
                "\n" .
                "������������, $ulogin!\n" .
                "\n" .
                "$warning_text.\n" .
                "\n" .
                "����������� � ��������� ����� ��������� ���� �ޣ�, ����� ��� ������\n" .
                "� ������ ������� ����� ������ ����� ����������� ��������.\n" .
                "\n" .
                "����������, ��� �� ��������� �� ��������� ����� \"$ukname\".\n" .
                "\n" .
                "��� ��������� ����� ��������� ���������� � ��������� ������ �ޣ��\n" .
                "����������� ��� ���������� �� ������:\n" .
                "\n" .
                "    https://billing.silvercom.net/statlogin.php?login=$ulogin\n" .
                "\n" .
                "�� �������� ������ ����������� �� ��������� 236-49-35, 216-33-53.\n" .
                "\n" .
                "������� �� ��������. �������� �� ���������� ��������������.\n" .
                "\n" .
                "-- \n" .
                "� ���������,\n" .
                "���ޣ���� ����� SilverCom\n" .
                "\n"
            );

            unless (defined(close(SENDMAIL))) {
                $debug->write(DEBUG_WARNING, "Can't close(): $!");
                next;
            }

            unless (defined($user->update_unotified($time_now))) {
                $debug->write(
                    DEBUG_ERROR,
                    "Can't catty::user->update_unotified(): " . $user->{'error'}
                );
                next;
            }

        } else {
            unless (exec('/usr/sbin/sendmail', '-t')) {
                $debug->write(DEBUG_ERROR, "Can't exec(): $!");
                exit(-1);
            }
        }
    }

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
    DEBUG_DEBUG,
    "Disconnecting from MySQL-server at " . $conf->{'mysql_r_host'}
);
unless (defined($dbh_r->disconnect)) {
    $debug->write(DEBUG_ERROR, "Can't DBI::db->close(): " . $dbh_c->errstr);
}


# �������� ���������� ����������������

$debug->write(
    DEBUG_DEBUG, "My last words before I will close logs"
);
unless (defined($debug->close)) {
    warn("Can't debug->close(): $debug->{'error'}");
    # exit(-1);
}


