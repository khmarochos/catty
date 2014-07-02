#!/usr/bin/perl
#
#   $Id$
#
#   external_check.pl, checks account for specified user
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
use catty::configure::external_check;
use catty::user;

# Библиотеки пакета

use debug qw(:debug_levels);
use timestamp;

# Библиотеки "слева"

use Getopt::Std;
use DBI;
use POSIX qw(strftime);
use Crypt::PasswdMD5;
use NetAddr::IP;


# Получаем конфигурационные данные

my $conf = catty::configure::external_check->new;
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


# Который час?

my $time_now = strftime("%Y-%m-%d %H:%M:%S", localtime);
$debug->write(
    DEBUG_DEBUG,
    "System clock shows: $time_now (" . timestamp2unixtime($time_now) . ")"
);


# Основной цикл

my $access_denied = -1;

while (1) {

    if (
        ($conf->{'username'}        =~ /^\d{7}$/) &&
        ($conf->{'phone_number'}    ne '5381010')
    ) {

        # Обработка тестера

        $debug->write(DEBUG_DEBUG, "Got testing request for $conf->{'username'}");

        unless (substr($conf->{'phone_number'}, -7) eq $conf->{'username'}) {
            $debug->write(DEBUG_INFO, "Login name and phone number mismatch!");
            $access_denied = 1;
            last;
        }


        # Подготавливаем SQL-транзакции
        
        my $sth_get_manager = $dbh_c->prepare(
            "SELECT " .
                "mid " .
            "FROM managers " .
            "WHERE " .
                "mlogin = ? AND " .
                "mactive != 0"
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
        
        my $sth_get_catty_payments_pexpire = $dbh_c->prepare(
            "SELECT MAX(pexpire) " .
            "FROM payments " .
            "WHERE " .
                "puser = ? AND " .
                "ppack = 1 AND " .
                "ppaid != 0 AND " .
                "paborted = 0"
        );
        
        my $sth_insert_catty_payments = $dbh_c->prepare(
            "INSERT INTO payments " .
            "SET " .
                "pid = NULL, " .
                "puser = ?, " .
                "psum = ?, " .
                "ppaydate = ?, " .
                "pcreate = ?, " .
                "pexpire = ?, " .
                "pmanager = ?, " .
                "ppaid = 1, " .
                "paborted = 0, " .
                "ptype = 0, " .
                "ppack = 1"
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


        # Получаем сведения о менеджере

        $debug->write(DEBUG_DEBUG, "Getting ID of manager $conf->{'manager'}");
        
        unless (defined($sth_get_manager->execute($conf->{'manager'}))) {
            $debug->write(DEBUG_ERROR, "Can't DBI::st->execute(): " . $dbh_c->errstr);
            last;
        }
        
        my ($mid) = $sth_get_manager->fetchrow_array();
        
        unless (defined($sth_get_manager->finish)) {
            $debug->write(DEBUG_ERROR, "Can't DBI::st->finish(): " . $dbh_c->errstr);
            last;
        }
        
        unless (defined($mid)) {
            $debug->write(DEBUG_ERROR, "Can't recognize manager '$conf->{'manager'}'");
            last;
        }
        
        $debug->write(
            DEBUG_DEBUG,
            "Manager $conf->{'manager'} has ID $mid"
        );


        # Запрашиваем id записи об этом пользователе в таблице users базы
        # catty
        
        $debug->write(
            DEBUG_DEBUG,
            "Gettig ID of record about $conf->{'username'} in catty:users"
        );
        
        unless (defined($sth_get_catty_users_uid->execute($conf->{'username'}))) {
            $debug->write(
                DEBUG_ERROR, "Can't DBI::st->execute(): " . $dbh_c->errstr
            );
            last;
        }
        
        my ($catty_users_uid) = $sth_get_catty_users_uid->fetchrow_array;
        
        unless (defined($sth_get_catty_users_uid->finish)) {
            $debug->write(
                DEBUG_ERROR, "Can't DBI::st->finish(): " . $dbh_c->errstr
            );
            last;
        }
        
        unless (defined($catty_users_uid)) {
        
            # Если id не определён, это значит, что пользователя пока нет в базе
            # и что его нужно внести
        
            $debug->write(
                DEBUG_INFO,
                "$conf->{'username'} is a new user, creating record in catty:users"
            );
        
            unless (defined($sth_insert_catty_users->execute(
                $conf->{'username'},
                "Тестовый пользователь: $conf->{'username'}",
                $conf->{'testers_upack'},
                $mid,
                $conf->{'testers_ulevel'},
                $time_now
            ))) {
                $debug->write(
                    DEBUG_ERROR, "Can't DBI::st->execute(): " . $dbh_c->errstr
                );
                last;
            }
        
            $catty_users_uid = $dbh_c->{'mysql_insertid'};
        
            unless (defined($catty_users_uid)) {
                $debug->write(
                    DEBUG_ERROR,
                    "ID of user $conf->{'username'} is still undefined!"
                );
                last;
            }
        
        } else {
        
            # Если id определён, проверим, нет ли каких проблем с ulevel/mlevel?
            
            $debug->write(
                DEBUG_DEBUG, "Getting security level of $conf->{'username'}"
            );
        
            unless (defined($sth_get_catty_users_ulevel->execute($conf->{'username'}))) {
                $debug->write(
                    DEBUG_ERROR, "Can't DBI::st->execute(): " . $dbh_c->errstr
                );
                last;
            }
        
            my ($catty_users_ulevel) = $sth_get_catty_users_ulevel->fetchrow_array;
        
            unless (defined($sth_get_catty_users_ulevel->finish)) {
                $debug->write(
                    DEBUG_ERROR, "Can't DBI::st->finish(): " . $dbh_c->errstr
                );
                last;
            }
        
            if ($catty_users_ulevel > $conf->{'testers_ulevel'}) {
                $debug->write(
                    DEBUG_ERROR,
                    "Name $conf->{'username'} is reserved for future usage"
                );
                last;
            }
        
        }
        
        
        # Запрашиваем id записи об этом пользователе в таблице radcheck базы
        # radius
        
        $debug->write(
            DEBUG_DEBUG,
            "Gettig ID of record about " .
            "$conf->{'username'} in radius:radcheck"
        );
        
        unless (defined($sth_get_radius_radcheck_id->execute(
            $conf->{'username'}
        ))) {
            $debug->write(
                DEBUG_ERROR,
                "Can't DBI::st->execute(): " . $dbh_r->errstr
            );
            last;
        }
        
        my ($radius_radcheck_id) = $sth_get_radius_radcheck_id->fetchrow_array;
        
        unless (defined($sth_get_radius_radcheck_id->finish)) {
            $debug->write(
                DEBUG_ERROR,
                "Can't DBI::st->finish(): " . $dbh_r->errstr
            );
            last;
        }
        
        unless (defined($radius_radcheck_id)) {
        
            # Если для него записи ещё нет - создаём её
        
            $debug->write(
                DEBUG_INFO,
                "$conf->{'username'} is a new user, creating record in radius:radcheck"
            );
        
            unless (defined($sth_insert_radius_radcheck->execute(
                $conf->{'username'},
                unix_md5_crypt('test')
            ))) {
                $debug->write(
                    DEBUG_ERROR,
                    "Can't DBI::st->execute(): " . $dbh_r->errstr
                );
                last;
            }
        
        }
        
        # Запрашиваем id записи об этом пользователе в таблице usergroup
        # radius
        
        
        $debug->write(
            DEBUG_DEBUG,
            "Gettig ID of record about " .
            "$conf->{'username'} in radius:usergroup"
        );
        
        unless (defined($sth_get_radius_usergroup_id->execute(
            $conf->{'username'}
        ))) {
            $debug->write(
                DEBUG_ERROR,
                "Can't DBI::st->execute(): " . $dbh_r->errstr
            );
            last;
        }
        
        my ($radius_usergroup_id) = $sth_get_radius_usergroup_id->fetchrow_array;
        
        unless (defined($sth_get_radius_usergroup_id->finish)) {
            $debug->write(
                DEBUG_ERROR,
                "Can't DBI::st->finish(): " . $dbh_r->errstr
            );
            last;
        }
        
        unless (defined($radius_usergroup_id)) {
        
            # Если для него записи ещё нет - создаём её
        
            $debug->write(
                DEBUG_INFO,
                "$conf->{'username'} is a new user, creating record"
            );
        
            unless (defined($sth_insert_radius_usergroup->execute(
                $conf->{'username'},
                $conf->{'testers_group'}
            ))) {
                $debug->write(
                    DEBUG_ERROR,
                    "Can't DBI::st->execute(): " . $dbh_r->errstr
                );
                last;
            }
    
        }
    
        # Получаем конечную дату последнего платежа
    
        $debug->write(
            DEBUG_DEBUG,
            "Getting expiration date of last payment for $conf->{'username'}"
        );
    
        unless (defined(
            $sth_get_catty_payments_pexpire->execute($catty_users_uid)
        )) {
            $debug->write(
                DEBUG_ERROR, "Can't DBI::st->execute(): " . $dbh_c->errstr
            );
            last;
        }
    
        my ($catty_payments_pexpire) = $sth_get_catty_payments_pexpire->fetchrow_array;
    
        unless (defined($sth_get_catty_payments_pexpire->finish)) {
            $debug->write(
                DEBUG_ERROR, "Can't DBI::st->finish(): " . $dbh_c->errstr
            );
            last;
        }
    
        if (
            (! defined($catty_payments_pexpire)) ||
            (timestamp2unixtime($catty_payments_pexpire) < timestamp2unixtime($time_now))
        ) {
    
            # Вносим новый платёж
    
            $debug->write(
                DEBUG_INFO, "Updating balance of $conf->{'username'}"
            );
    
            unless (defined($sth_insert_catty_payments->execute(
                $catty_users_uid,
                0.4,
                $time_now,
                $time_now,
                unixtime2timestamp(timestamp2unixtime($time_now) + 7257600),
                $mid
            ))) {
                $debug->write(
                    DEBUG_ERROR, "Can't DBI::st->execute(): " . $dbh_c->errstr
                );
                last;
            }
        }
    }

    # Обычная обработка пользователя

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
            DEBUG_ERROR,
            "Undefined username, can't work"
        );
        last;
    }
    
    unless (defined($sth_get_users->execute(
        $conf->{'username'},
        $conf->{'manager'}
    ))) {
        $debug->write(DEBUG_ERROR, "Can't DBI::st->execute(): " . $dbh_c->errstr);
        last;
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
        last;
    }
    
    
    # Если мы никого не нашли, значит все очень хорошо поныкались:)
    
    if (scalar(@users_to_check) == 0) {
        $debug->write(DEBUG_ERROR, "User not found");
        last;
    } elsif (scalar(@users_to_check) > 1) {
        $debug->write(DEBUG_ERROR, "Too many entries found");
        last;
    }
    
    
    # Проверка баланса пользователя
    
    my $user = @users_to_check[0];
    
    $debug->write(
        DEBUG_DEBUG, "Calculating balance for user " . $user->{'ulogin'}
    );
    unless (defined($user->check_balance(undef, $time_now))) {
        $debug->write(
            DEBUG_ERROR,
            "Can't catty::user->check_balance(): " . $user->{'error'}
        );
        last;
    }
    
    
    # Проверка количества активных на данный момент подключений для него
    
    $debug->write(
        DEBUG_DEBUG,
        "Getting number of active sessions for user " . $user->{'ulogin'}
    );
    my $sth_get_number_of_sessions = $dbh_c->prepare(
        "SELECT COUNT(sid) " .
        "FROM sessions " .
        "WHERE " .
            "suser = ? AND " .
            "stime_stop = '0000-00-00 00:00:00'"
    );
    unless (defined($sth_get_number_of_sessions->execute($user->{'uid'}))) {
        $debug->write(
            DEBUG_ERROR,
            "Can't DBI::st->execute(): " . $dbh_c->errstr
        );
    }
    my ($number_of_sessions) = $sth_get_number_of_sessions->fetchrow_array;
    unless (defined($number_of_sessions)) {
        $debug->write(
            DEBUG_ERROR,
            "Undefined number of sessions for user " . $user->{'ulogin'}
        );
    }
    unless (defined($sth_get_number_of_sessions->finish)) {
        $debug->write(DEBUG_ERROR, "Can't DBI::st->finish(): " . $dbh_c->errstr);
        last;
    }
    $debug->write(
        DEBUG_DEBUG,
        "There is $number_of_sessions of active sessions now, maximum is " .
            "$user->{'uklogins'} for user $user->{'ulogin'}"
    );


    # А как насчёт коллбека?

    if (($user->{'ukcb'} == 1) && ($conf->{'call_back'})) {
        print("Cisco-AVPair = \"lcp:callback-dialstring=\",\n");
#        print("Ascend-CBCP-Enable = CBCP-Enabled,\n");
#        print("Ascend-CBCP-Mode = CBCP-Any-Or-No,\n");
#        print("Ascend-CBCP-Trunk-Group = 9,\n");
#        print("Ascend-Data-Svc = Switched-modem,\n");
#        print("Ascend-Send-Auth = Send-Auth-None,\n");
    }


    # Проверим, как насчёт динамических пуллов

    if (
        defined($conf->{'ip_address_first'}) &&
        defined($conf->{'ip_address_last'}) &&
        defined($conf->{'ip_address_used'})
    ) {
        $debug->write(
            DEBUG_DEBUG,
            "This user may be associated with specific IP-address pool"
        );

        my $ip_address_used = $conf->{'ip_address_first'};
        $debug->write(
            DEBUG_DEBUG,
            "Looking for watermark at $conf->{'ip_address_used'}"
        );
        while (1) {
            unless (defined(open(IP_ADDRESS_USED, "<$conf->{'ip_address_used'}"))) {
                $debug->write(
                    DEBUG_WARNING,
                    "Watermark not found at $conf->{'ip_address_used'}, creating it"
                );
                last;
            }
            while (<IP_ADDRESS_USED>) {
                chomp;
                if (/^\s*[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\s*$/) {
                    $ip_address_used = $_;
                }
            }
            unless (close(IP_ADDRESS_USED)) {
                $debug->write(DEBUG_ERROR, "Can't close(): $!");
                last;
            }
            last;
        }

        my $ip_address_first    = NetAddr::IP->new($conf->{'ip_address_first'});
        my $ip_address_last     = NetAddr::IP->new($conf->{'ip_address_last'});
        my $ip_address_used     = NetAddr::IP->new($ip_address_used);
        my $ip_address_new;

        if ($ip_address_used->numeric >= $ip_address_last->numeric) {
            $ip_address_new = NetAddr::IP->new($ip_address_first->addr)
        } else {
            $ip_address_new = NetAddr::IP->new($ip_address_used->numeric + 1);
        }

        $debug->write(
            DEBUG_INFO,
            "User $conf->{'username'} got an address " . $ip_address_new->addr
        );

        print("Framed-IP-Address = \"" . $ip_address_new->addr . "\"\n");

        unless (defined(open(IP_ADDRESS_USED, ">$conf->{'ip_address_used'}"))) {
            $debug->write(DEBUG_ERROR, "Can't open(): $!");
            last;
        }
        print(IP_ADDRESS_USED $ip_address_new->addr . "\n");
        unless (close(IP_ADDRESS_USED)) {
            $debug->write(DEBUG_ERROR, "Can't close(): $!");
            last;
        }

    } else {

        print("Framed-IP-Address = \"255.255.255.254\"\n");

    }

    
    # Всё прочее...

    if (
        (
            # Если максимальное количество одновременных сессий достигнуто...
            (
                $number_of_sessions >= $user->{'uklogins'}
            ) && (
                $debug->write(
                    DEBUG_INFO,
                    "$user->{'ulogin'}: maximum number of connections has been reached"
                ) || print("Reply-Message = \"Too many sessions!\"\n") || 1
            )
        ) || (
            ! (
                $user->{'udbtr'} &&
                timestamp2unixtime($user->{'udbtrd'}) > timestamp2unixtime($time_now)
            )
        ) && (
            (
                # Если его счёт уже закрыт...
                (
                    timestamp2unixtime($user->{'uexpire'}) <=
                    timestamp2unixtime($time_now)
                ) && (
                    $debug->write(
                        DEBUG_INFO,
                        "$user->{'ulogin'}: account is expired"
                    ) || print("Reply-Message = \"Your account is expired!\"\n") || 1
                )
            ) || (
                # Если это почасовой или "удобный" пользователь и его баланс уже в жопе
                (
                    (($user->{'uktid'} == 1) || ($user->{'uktid'} == 3)) &&
                    ($user->{'ubalance'} < 0)
                ) && (
                    $debug->write(
                        DEBUG_INFO,
                        "$user->{'ulogin'}: account is empty"
                    ) || print("Reply-Message = \"Your account is empty!\"\n") || 1
                )
            ) || (
                # Если это пакетный или удобный пользователь и срок истечения
                # действия его платежа уже исчерпан
                (
                    (($user->{'uktid'} == 2) || ($user->{'uktid'} == 3)) &&
                    (
                        (
                            timestamp2unixtime($user->{'ulpexpire'}) <=
                            timestamp2unixtime($time_now)
                        )
                    )
                ) && (
                    $debug->write(
                        DEBUG_INFO,
                        "$user->{'ulogin'}: all payments is expired"
                    ) || print("Reply-Message = \"All of your payments is expired!\"\n") || 1
                )
            ) || (
                (
                    ($user->{'ulogin'} eq 'goga') && (
                        ($conf->{'phone_number'} ne '80442744107') &&
                        ($conf->{'phone_number'} ne '5381010')
                    )
                ) && (
                    $debug->write(
                        DEBUG_INFO,
                        "$user->{'ulogin'}: Denied phone number"
                    ) || print("Reply-Message = \"Denied phone number!\"\n") || 1
                )
            )
        )
    ) {
        $access_denied = 1;
    } else {
        $access_denied = 0;
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

$debug->write(
    DEBUG_DEBUG,
    "Disconnecting from MySQL-server at " . $conf->{'mysql_r_host'}
);
unless (defined($dbh_r->disconnect)) {
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

exit($access_denied);

