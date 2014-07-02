#!/usr/bin/perl
#
#   $Id$
#
#   559.pl, assistance module for "Internet-559" project
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
use catty::configure::559;
use catty::user;

# Библиотеки пакета

use debug qw(:debug_levels);
use timestamp;

# Библиотеки "слева"

use Getopt::Std;
use LWP;
use LWP::UserAgent;
use HTTP::Request::Common;
use URI;
use DBI;
use Crypt::PasswdMD5;
use Digest::MD5 qw(md5_hex);
use POSIX qw(strftime);


# Получаем конфигурационные данные

my $conf = catty::configure::559->new;
unless (defined($conf)) {
    exit(-1);
}


# Открываем интерфейс протоколирования 

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


# Взводим user-agent

my $ua = LWP::UserAgent->new(
    agent       => "559.pl; libwww/perl-$LWP::VERSION"
);


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

$debug->write(
    DEBUG_DEBUG, "Connecting to SQL-server at " . $conf->{'mysql_f_host'}
);
my $dbh_f = DBI->connect(
    "DBI:mysql:database=" . $conf->{'mysql_f_db'} .
        ";host=" . $conf->{'mysql_f_host'},
    $conf->{'mysql_f_login'},
    $conf->{'mysql_f_passwd'},
    {
        PrintError => 0
    }
);
unless (defined($dbh_f)) {
    $debug->write(DEBUG_ERROR, "Can't DBI::db->connect(): $DBI::errstr");
    exit(-1);
}


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

my $sth_get_operator = $dbh_f->prepare(
    "SELECT " .
        "rname, " .
        "rurl, " .
        "rlogin, " .
        "rpassword, " .
        "rcertsubject " .
    "FROM roaming " .
    "WHERE rid = ?"
);

my $sth_log_transaction = $dbh_f->prepare(
    "INSERT INTO calls " .
    "SET " .
        "cphonenum = ?, " .
        "ctime = ?, " .
        "cseconds = ?, " .
        "coperator = ?, " .
        "cmanager = ?"
);

my $sth_get_catty_users_uid = $dbh_c->prepare(
    "SELECT uid " .
    "FROM users " .
    "WHERE ulogin = ?"
);

my $sth_get_catty_users_ulevel = $dbh_c->prepare(
    "SELECT ulevel " .
    "FROM users " .
    "WHERE uid = ?"
);

my $sth_get_radius_radcheck_id = $dbh_r->prepare(
    "SELECT id " .
    "FROM radcheck " .
    "WHERE " .
        "UserName = ? AND " .
        "Attribute = 'User-Password' AND " .
        "op = ':='"
);

my $sth_get_radius_usergroup_id = $dbh_r->prepare(
    "SELECT id " .
    "FROM usergroup " .
    "WHERE " .
        "UserName = ?"
);

my $sth_update_radius_radcheck = $dbh_r->prepare(
    "UPDATE radcheck " .
    "SET Value = ? " .
    "WHERE id = ?"
);

my $sth_update_radius_usergroup = $dbh_r->prepare(
    "UPDATE usergroup " .
    "SET GroupName = ? " .
    "WHERE id = ?"
);

my $sth_insert_catty_users = $dbh_c->prepare(
    "INSERT INTO users " .
    "SET " .
        "uid = NULL, " .
        "uadog = 0, " .
        "ulogin = ?, " .
        "uname = ?, " .
        "upack = ?, " .
        "udbtr = 0, " .
        "udbtrd = '2038-01-19 05:14:07', " .
        "umanager = ?, " .
        "ulevel = ?, " .
        "ucreate = ?, " .
        "uexpire = '2038-01-19 05:14:07', " .
        "unotified = '2000-01-01 00:00:00', " .
        "unotifiedc = 0, " .
        "udeleted = 0"
);

my $sth_insert_catty_payments = $dbh_c->prepare(
    "INSERT INTO payments " .
    "SET " .
        "pid = NULL, " .
        "puser = ?, " .
        "psum = ?, " .
        "ppaydate = ?, " .
        "pcreate = ?, " .
        "pexpire = '2038-01-19 05:14:07', " .
        "pmanager = ?, " .
        "ppaid = 1, " .
        "paborted = 0, " .
        "ptype = 0, " .
        "ppack = 1"
);

my $sth_insert_radius_radcheck = $dbh_r->prepare(
    "INSERT INTO radcheck " .
    "SET " .
        "id = NULL, " .
        "UserName = ?, " .
        "Attribute = 'User-Password', " .
        "op = ':=', " .
        "Value = ?"
);

my $sth_insert_radius_usergroup = $dbh_r->prepare(
    "INSERT INTO usergroup " .
    "SET " .
        "id = NULL, " .
        "UserName = ?, " .
        "GroupName = ?"
);


# Который час?

my $time_now = strftime("%Y-%m-%d %H:%M:%S", localtime);
$debug->write(
    DEBUG_DEBUG,
    "System clock shows: $time_now (" . timestamp2unixtime($time_now) . ")"
);


# Получаем номер менеджера

$debug->write(DEBUG_DEBUG, "Getting ID of manager");

unless (defined($sth_get_manager->execute($conf->{'manager'}))) {
    $debug->write(DEBUG_ERROR, "Can't DBI::st->execute(): " . $dbh_c->errstr);
    exit(-1);
}

my ($mid, $mlevel) = $sth_get_manager->fetchrow_array();

unless (defined($sth_get_manager->finish)) {
    $debug->write(DEBUG_ERROR, "Can't DBI::st->finish(): " . $dbh_c->errstr);
    exit(-1);
}

unless (defined($mid) && defined($mlevel)) {
    $debug->write(DEBUG_ERROR, "Can't recognize manager '$conf->{'manager'}'");
    exit(-1);
}

$debug->write(
    DEBUG_DEBUG,
    "Manager $conf->{'manager'} has ID $mid and level $mlevel"
);


# Интересуемся, какого хуя от нас хотят

$debug->write(DEBUG_DEBUG, "Getting commands from STDIN");

my @transactions;

while (<>) {
    chomp;

    $debug->write(DEBUG_DEBUG, "Got string '$_' from STDIN");

    if (/^(380(67|97|50|66)\d{7}):(\S{1,15}):(\d{1,}):(\d{1,})$/) {
        $debug->write(DEBUG_DEBUG, "Valid string: '$_'");
        my $transaction;
           $transaction->{'phonenum'}   = $1;
           $transaction->{'password'}   = $3;
           $transaction->{'seconds'}    = $4;
           $transaction->{'operator'}   = $5;
           $transaction->{'manager'}    = $mid;
           $transaction->{'time'}       = $time_now;
        push(@transactions, $transaction);
        next;
    } else {
        $debug->write(DEBUG_WARNING, "Invalid string: '$_'");
        next;
    }
}


# Проводим все транзакции

$debug->write(DEBUG_DEBUG, "Running transactions");

for my $transaction (
    sort({$a->{'operator'} cmp $b->{'operator'}} @transactions)
) {

    # Опознаём оператора

    $debug->write(
        DEBUG_DEBUG,
        "Getting info about operator identified by " .
        "ID $transaction->{'operator'}"
    );

    unless (defined($sth_get_operator->execute($transaction->{'operator'}))) {
        $debug->write(DEBUG_ERROR, "Can't DBI::st->execute(): " . $dbh_f->errstr);
        next;
    }

    my (
        $rname,
        $rurl,
        $rlogin,
        $rpassword,
        $rcertsubject
    ) = $sth_get_operator->fetchrow_array;

    unless (defined($sth_get_operator->finish)) {
        $debug->write(DEBUG_ERROR, "Can't DBI::st->finish(): " . $dbh_f->errstr);
        next;
    }

    unless (
        defined($rname) &&
        defined($rurl) &&
        defined($rlogin) &&
        defined($rpassword) &&
        defined($rcertsubject)
    ) {
        $debug->write(
            DEBUG_ERROR,
            "Can't recognize operator by ID $transaction->{'operator'}"
        );
        next;
    }

    $debug->write(
        DEBUG_DEBUG,
        "Operator '$rname' recognized by ID $transaction->{'operator'}"
    );


    # Проводим непосредственно транзакцию


#    # Включаем режим ручного подтверждения транзакций
#
#    $debug->write(DEBUG_DEBUG, "Disabling autocommit for all of databases");
#
#    $dbh_c->{'AutoCommit'} = 0;
#    unless ($dbh_c->{'AutoCommit'} == 0) {
#        $debug->write(
#            DEBUG_ERROR,
#            "Can't change DBI::db->{'AutoCommit'} in catty database: " .
#                $dbh_c->errstr
#        );
#        last;
#    }
#    
#    $dbh_r->{'AutoCommit'} = 0;
#    unless ($dbh_r->{'AutoCommit'} == 0) {
#        $debug->write(
#            DEBUG_ERROR,
#            "Can't change DBI::db->{'AutoCommit'} in radius database: " .
#                $dbh_r->errstr
#        );
#        last;
#    }
#    
#    $dbh_f->{'AutoCommit'} = 0;
#    unless ($dbh_f->{'AutoCommit'} == 0) {
#        $debug->write(
#            DEBUG_ERROR,
#            "Can't change DBI::db->{'AutoCommit'} in fivefivenine database: " .
#                $dbh_f->errstr
#        );
#        last;
#    }


    if ($rurl =~ /LOCAL/i) {

        $debug->write(DEBUG_DEBUG, "Operator '$rname' is local");


        # Запрашиваем id записи об этом пользователе в таблице users базы
        # catty

        $debug->write(
            DEBUG_DEBUG,
            "Gettig ID of record about $transaction->{'phonenum'} " .
            "in catty:users"
        );

        unless (defined($sth_get_catty_users_uid->execute(
            $transaction->{'phonenum'}
        ))) {
            $debug->write(
                DEBUG_ERROR,
                "Can't DBI::st->execute(): " . $dbh_c->errstr
            );
            next;
        }

        my ($catty_users_uid) = $sth_get_catty_users_uid->fetchrow_array;

        unless (defined($sth_get_catty_users_uid->finish)) {
            $debug->write(
                DEBUG_ERROR,
                "Can't DBI::st->finish(): " . $dbh_c->errstr
            );
            next;
        }

        unless (defined($catty_users_uid)) {

            # Если id неопределён, это значит, что пользователя пока нет в базе
            # и что его нужно внести

            $debug->write(
                DEBUG_DEBUG,
                "$transaction->{'phonenum'} is a new user, creating record"
            );

            unless (defined($sth_insert_catty_users->execute(
                $transaction->{'phonenum'},
                "Пользователь Интернет-559: $transaction->{'phonenum'}",
                $conf->{'users_upack'},
                $mid,
                $mlevel,
                $time_now
            ))) {
                $debug->write(
                    DEBUG_ERROR,
                    "Can't DBI::st->execute(): " . $dbh_c->errstr
                );
                next;
            }

            $catty_users_uid = $dbh_c->{'mysql_insertid'};

            unless (defined($catty_users_uid)) {
                $debug->write(
                    DEBUG_ERROR,
                    "ID of user $transaction->{'phonenum'} is still undefined!"
                );
                next;
            }

        } else {


            # Если id стал нам известен, проверяем уровень доступа

            $debug->write(
                DEBUG_DEBUG,
                "$transaction->{'phonenum'} exists, checking level permissions"
            );

            unless (defined($sth_get_catty_users_ulevel->execute(
                $catty_users_uid
            ))) {
                $debug->write(
                    DEBUG_ERROR,
                    "Can't DBI::st->execute(): " . $dbh_c->errstr
                );
                next;
            }

            my ($catty_users_ulevel) = $sth_get_catty_users_ulevel->fetchrow_array;

            unless (defined($sth_get_catty_users_ulevel->finish)) {
                $debug->write(
                    DEBUG_ERROR,
                    "Can't DBI::st->finish(): " . $dbh_c->errstr
                );
                next;
            }

            unless (defined($catty_users_ulevel)) {
                $debug->write(
                    DEBUG_ERROR,
                    "Undefined security level of user $transaction->{'phonenum'}"
                );
                next;
            }

            if ($catty_users_ulevel > $mlevel) {
                $debug->write(
                    DEBUG_ERROR,
                    "Name $transaction->{'phonenum'} is reserved for future usage"
                );
                next;
            }

        }


        # Запрашиваем id записи об этом пользователе в таблице radcheck базы
        # radius

        $debug->write(
            DEBUG_DEBUG,
            "Gettig ID of record about " .
            "$transaction->{'phonenum'} in radius:radcheck"
        );

        unless (defined($sth_get_radius_radcheck_id->execute(
            $transaction->{'phonenum'}
        ))) {
            $debug->write(
                DEBUG_ERROR,
                "Can't DBI::st->execute(): " . $dbh_r->errstr
            );
            next;
        }

        my ($radius_radcheck_id) = $sth_get_radius_radcheck_id->fetchrow_array;

        unless (defined($sth_get_radius_radcheck_id->finish)) {
            $debug->write(
                DEBUG_ERROR,
                "Can't DBI::st->finish(): " . $dbh_r->errstr
            );
            next;
        }

        unless (defined($radius_radcheck_id)) {

            $debug->write(
                DEBUG_DEBUG,
                "$transaction->{'phonenum'} is a new user, creating record"
            );

            unless (defined($sth_insert_radius_radcheck->execute(
                $transaction->{'phonenum'},
                unix_md5_crypt($transaction->{'password'})
            ))) {
                $debug->write(
                    DEBUG_ERROR,
                    "Can't DBI::st->execute(): " . $dbh_r->errstr
                );
                next;
            }

        } else {

            $debug->write(
                DEBUG_DEBUG,
                "$transaction->{'phonenum'} exists, updating password"
            );

            unless (defined($sth_update_radius_radcheck->execute(
                unix_md5_crypt($transaction->{'password'}),
                $transaction->{'phonenum'}
            ))) {
                $debug->write(
                    DEBUG_ERROR,
                    "Can't DBI::st->execute(): " . $dbh_r->errstr
                );
                next;
            }

        }

        # Запрашиваем id записи об этом пользователе в таблице usergroup
        # radius


        $debug->write(
            DEBUG_DEBUG,
            "Gettig ID of record about " .
            "$transaction->{'phonenum'} in radius:usergroup"
        );

        unless (defined($sth_get_radius_usergroup_id->execute(
            $transaction->{'phonenum'}
        ))) {
            $debug->write(
                DEBUG_ERROR,
                "Can't DBI::st->execute(): " . $dbh_r->errstr
            );
            next;
        }

        my ($radius_usergroup_id) = $sth_get_radius_usergroup_id->fetchrow_array;

        unless (defined($sth_get_radius_usergroup_id->finish)) {
            $debug->write(
                DEBUG_ERROR,
                "Can't DBI::st->finish(): " . $dbh_r->errstr
            );
            next;
        }

        unless (defined($radius_usergroup_id)) {

            $debug->write(
                DEBUG_DEBUG,
                "$transaction->{'phonenum'} is a new user, creating record"
            );

            unless (defined($sth_insert_radius_usergroup->execute(
                $transaction->{'phonenum'},
                $conf->{'users_group'}
            ))) {
                $debug->write(
                    DEBUG_ERROR,
                    "Can't DBI::st->execute(): " . $dbh_r->errstr
                );
                next;
            }

        }


        # Начисляем платёж

        $transaction->{'payment_sum'} = ($transaction->{'seconds'} / 60) * 3;

        $debug->write(
            DEBUG_DEBUG,
            "Adding payment for $transaction->{'seconds'} seconds to " .
            "account of user $transaction->{'phonenum'} " .
            "($transaction->{'payment_sum'}\$)"
        );

        unless (defined($sth_insert_catty_payments->execute(
            $catty_users_uid,
            $transaction->{'payment_sum'},
            $transaction->{'time'},
            $transaction->{'time'},
            $mid
        ))) {
            $debug->write(
                DEBUG_ERROR,
                "Can't DBI::st->execute(): " . $dbh_c->errstr
            );
            next;
        }

    } else {
    
        $debug->write(
            DEBUG_DEBUG,
            "Operator '$rname' must be managed via '$rurl'"
        );


        $ua->credentials(
            (URI->new($rurl)->host . ":443"),
            $conf->{'http_auth_realm'},
            $rlogin,
            $rpassword
        );

        my $res = $ua->request(
            POST(
                $rurl,
                [
                    action      => 'add',
                    login       => $transaction->{'phonenum'},
                    password    => md5_hex($transaction->{'password'}),
                    time        => $transaction->{'seconds'}
                ],
                'If-SSL-Cert-Subject'   => $rcertsubject
            )
        );

        unless ($res->is_success) {
            $debug->write(
                DEBUG_ERROR,
                "Can't LWP::UserAgent->request(): " . $res->status_line
            );
            next;
        }

        my $res_content = $res->content; chomp($res_content);

        $debug->write(
            DEBUG_DEBUG,
            "HTTP-agent returns: $res_content"
        );

        unless ($res_content =~ /^OK$/i) {
            $debug->write(
                DEBUG_ERROR,
                "Remote server reports an error: $res_content"
            );
            next;
        }

    }


    # Хвастаемся:)

    $debug->write(
        DEBUG_INFO,
        "OK! Transaction for $transaction->{'phonenum'} is done"
    );


    # Отсылаем SMS

    my $email;

    if ($transaction->{'phonenum'} =~ /^380(67|97)\d{7}$/) {
        $email = $transaction->{'phonenum'} . "\@2sms.kyivstar.net";
    } elsif ($transaction->{'phonenum'} =~ /^380(50|66)\d{7}$/) {
        $email = $transaction->{'phonenum'} . "\@sms.umc.com.ua";
    }

    $debug->write(
        DEBUG_DEBUG,
        "Sending SMS to $transaction->{'phonenum'} via $email"
    );

    my $new_pid = open(SENDMAIL, '|-');

    if (! defined($new_pid)) {
        $debug->write(DEBUG_ERROR, "Can't fork(): $!");
    } elsif ($new_pid > 0) {

        print(SENDMAIL
            "From: <billing\@silvercom.net>\n" .
            "To: <$email>\n" .
            "Cc: <billing\@silvercom.net>, <korn\@059.com.ua>\n" .
            "Subject: Internet-559\n" .
            "\n" .
            "Dobro pozhalovat' v \"Internet-559\"!\n" .
            "Vash login: $transaction->{'phonenum'}\n" .
            "Vash parol': $transaction->{'password'}\n"
        );

        unless (defined(close(SENDMAIL))) {
            $debug->write(DEBUG_WARNING, "Can't close(): $!");
        }

    } else {
        unless (exec('/usr/sbin/sendmail', '-t')) {
            $debug->write(DEBUG_ERROR, "Can't exec(): $!");
        }
    }


    # Записываем информацию об успешно проведённой транзакции

    $debug->write(
        DEBUG_DEBUG,
        "Writing information about successfull transaction of " .
        "manager $conf->{'manager'}"
    );

    unless (defined($sth_log_transaction->execute(
        $transaction->{'phonenum'},
        $transaction->{'time'},
        $transaction->{'seconds'},
        $transaction->{'operator'},
        $transaction->{'manager'}
    ))) {
        $debug->write(
            DEBUG_ERROR,
            "Can't DBI::st->execute(): " . $dbh_f->errstr
        );
        next;
    }


#    # Сохраняем транзакцию
#
#    $debug->write(DEBUG_DEBUG, "Committing transacton for all of databases");
#
#    unless (defined($dbh_c->commit)) {
#        $debug->write(DEBUG_ERROR, "Can't DBI::db->commit(): " . $dbh_c->errstr);
#        last;
#    }
#
#    unless (defined($dbh_r->commit)) {
#        $debug->write(DEBUG_ERROR, "Can't DBI::db->commit(): " . $dbh_r->errstr);
#        last;
#    }
#
#    unless (defined($dbh_f->commit)) {
#        $debug->write(DEBUG_ERROR, "Can't DBI::db->commit(): " . $dbh_f->errstr);
#        last;
#    }

} continue {


#    # Отменяем транзакцию
#
#    $debug->write(DEBUG_DEBUG, "Rolling back transacton for all of databases");
#
#    unless (defined($dbh_c->rollback)) {
#        $debug->write(DEBUG_ERROR, "Can't DBI::db->rollback(): " . $dbh_c->errstr);
#        last;
#    }
#
#    unless (defined($dbh_r->rollback)) {
#        $debug->write(DEBUG_ERROR, "Can't DBI::db->rollback(): " . $dbh_r->errstr);
#        last;
#    }
#
#    unless (defined($dbh_f->rollback)) {
#        $debug->write(DEBUG_ERROR, "Can't DBI::db->rollback(): " . $dbh_f->errstr);
#        last;
#    }

}


# Отключение от SQL-сервера

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
    $debug->write(DEBUG_ERROR, "Can't DBI::db->close(): " . $dbh_r->errstr);
}

$debug->write(
    DEBUG_DEBUG,
    "Disconnecting from MySQL-server at " . $conf->{'mysql_f_host'}
);
unless (defined($dbh_f->disconnect)) {
    $debug->write(DEBUG_ERROR, "Can't DBI::db->close(): " . $dbh_f->errstr);
}


# Закрытие интерфейса протоколирования

$debug->write(
    DEBUG_DEBUG, "My last words before I will close logs"
);
unless (defined($debug->close)) {
    warn("Can't debug->close(): $debug->{'error'}");
    # exit(-1);
}


