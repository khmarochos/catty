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


# Этот тарификатор будет охуенным...    (12-07-2002)
# Как же мне все это остопиздело!       (16-07-2002)
# Да, но зато какой он охуенный! ;-)    (08-04-2003)
# Просто пиздатейший, я согласен.       (09-04-2003)
# Да нет, он именно охуенный!           (10-04-2003)
# А мне до сраки                        (18-02-2004)

use strict;

use FindBin qw($Bin);

use lib "$Bin/../lib";

# Модули пакета

use catty::config qw(
    :CATTY_main
);
use catty::configure::nanny;
use catty::nas;
use catty::user;
use catty::session;

# Библиотеки пакета

use debug qw(:debug_levels);
use timestamp;

# Библиотеки "слева"

use Getopt::Std;
use DBI;
use POSIX qw(setsid setuid getuid getpwnam setgid getgid getgrnam strftime);


# Получаем конфигурационные данные

my $conf = catty::configure::nanny->new;
unless (defined($conf)) {
    exit(-1);
}


# Изменяем свои UID и GID

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


# Открываем интерфейс протоколирования 

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


# Демонизируемся при необходимости

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


# Меняем свое имя

$0 = "nanny.pl";


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

# Инициализируем основные SQL-транзакции для последующих вызовов

# Получение списка NAS'ов
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

# Получение списка открытых на данный момент сессий в базе RADIUS
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

# Получение списка открытых на данный момент сессий в базе Catty
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

# Закрытие "подвисшей" сессии в базе RADIUS
my $sth_r_close_stalled_session = $dbh_r->prepare(
    "UPDATE radacct " .
    "SET AcctStopTime = NOW() " .
    "WHERE " .
        "AcctUniqueId = ? AND " .
        "AcctStopTime = '0000-00-00 00:00:00'"
);

# Закрытие "подвисшей" сессии в базе Catty
my $sth_c_close_stalled_session = $dbh_c->prepare(
    "UPDATE sessions " .
    "SET stime_stop = NOW() " .
    "WHERE " .
        "ssession = ? AND " .
        "stime_stop = '0000-00-00 00:00:00'"
);


# Неклоторые важные переменные

my $time_now;   # Текущее значение таймера
my $time_was;   # Значение таймера при предыдущей итерации
my $time_start; # Значение таймера при старте тарификатора

my %sessions;   # Хэш сессий, где ключ - id сессии, знаечение - объект
my %nases;      # Хэш NAS'ов, где ключ - адрес NAS, значение - объект
my %users;      # Хэш пользователей, где ключ - логин-имя, значение - объект

my $stop_job;   # Как только вернет TRUE - останавливаем работу


# Получаем таблицу NAS'ов и инитим NAS-мониторы

$debug->write(DEBUG_DEBUG, "Initializing NAS-monitors");
unless (defined($sth_get_nases->execute)) {
    $debug->write(DEBUG_ERROR, "Can't DBI::st->execute(): " . $dbh_c->errstr);
    exit(-1);
}
while (
    my (
        $db_nid,        # Идентификатор записи о NAS
        $db_naddr,      # IP-адрес NAS
        $db_ncomm,      # RW-сообщество (SNMP) NAS
        $db_nsrac,      # S.upports R.adius AC.counting
        $db_nntbc,      # N.eed T.o B.e C.hecked
        $db_ntype,      # Тип NAS
        $db_nports      # Количество портов
    ) = $sth_get_nases->fetchrow_array
) {

    # Для каждого NAS инициализируем объект класса catty::nas

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


# Пускаем "вечный" цикл, не забыв перехватить сигналы

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

# Проверяем PID-файл

if (-r $conf->{'pid_file'}) {
    if ((stat($conf->{'pid_file'}))[9] < (time - $conf->{'step'} * 30)) {
        $debug->write(DEBUG_WARNING, "PID-file found, but seems to be stalled");
    } else {
        $debug->write(DEBUG_ERROR, "PID-file found, can't run");
        exit(-1);
    }
}


# Массив переменных длительности сна:)

my @to_sleep = ($conf->{'step'} x 10);

do {

    # Лениво вякаем...

    $debug->write(DEBUG_DEBUG, "*** Beginning new iteration ***");


    # Обновляем PID-файл
    
    unless (defined(write_pid($conf->{'pid_file'}))) {
        $debug->write(DEBUG_ERROR, "Can't write_pid()");
        last;
    }


    # Который час?

    $time_now = strftime("%Y-%m-%d %H:%M:%S", localtime);
    unless (defined($time_start)) {
        $time_start = $time_now;
    }

    $debug->write(
        DEBUG_DEBUG,
        "System clock shows: $time_now (" . timestamp2unixtime($time_now) . ")"
    );


    # Если это первая итерация и время исполнения предыдущей итерации еще не
    # устанавливалось в специательной переменной, исправляем это досадное
    # упущениэ, а заодно вякаем о своем рождениэ

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

    
    # Едут кони шеренгОй в славный город Уренгой (ц) ?


    # Получение списка активных сессий из базы RADIUS

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

        # Для каждой новой сессии, которой еще нет в хэше, мы инициализируем
        # объект класса catty::session и, если необходимо, инициализируем
        # объект класса catty::user для пользователя

        unless (defined($sessions{$db_acctsessionid})) {

            # Проверим валидность всех полученных параметров сессии
    
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

            # Если у нас еще нет в памяти объекта класса catty::user для этого
            # пользователя, инициализируем такой объект для дальнейшей работы

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

                    # Сохраняем получившийся объект в хэше объектов этого класса
                    # для дальнейшего поюзаниэ
                    
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

            # Инитим объект сессии

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

            # Идентификатор сессии сохраняем в хэше активных сессий в качестве
            # ключа, а сам объект - в качестве значения элемента

            $sessions{$db_acctsessionid} = $session_object;

            # Также сохраняем этот идентификатор в в объекте catty::user
            # соответствующего пользователя...

            ${$users{$db_username}->{'usessions'}}{$db_acctsessionid} =
                $session_object;

            # ...и в объекте catty::nas соответствующего NAS

            ${$nases{$db_nasipaddress}->{'sessions'}}{$db_acctsessionid} =
                $session_object;

        }
    }

    unless (defined($sth_r_get_opened_sessions->finish)) {
        $debug->write(DEBUG_ERROR, "Can't DBI::st->finish(): " . $dbh_r->errstr);
        # exit(-1);
    }


    # Обновляем данные о каждой из активных сессий из раиусной базейки
    
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

        # Опрашиваем RADIUS

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

        # Проверяем, не пиздит ли RADIUS и совпадают ли его сведения с
        # реальной картиной, если обратиться к NAS: в случае, если он
        # утверждает, что сессия всё ещё открыта, мы обратимся к NAS и
        # получим так называемый magic-номер, который _типа_ должен
        # будет измениться после закрытия порта (или вообще пойти по пизде),
        # чтобы затем проверить, совпадает ли он с тем, что у нас уже есть в
        # памяти.

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


    # Для каждой из активных сессий (не только тех, что были обнаружены
    # открытыми при этой итерации, а и для тех, кто еще считался открытыми в
    # момент предыдущего прогона!) выполняем тарификацию:
    #   1. Вычисляем количество времени, проведенное ним на связи с момента
    #      последнего тарификационного цикла (он мог успеть отвалиться,
    #      мог прилогиниться только сейчас, в конце-концов, мы могли попросту
    #      не уложить предыдущий прогон в указанный в параметрах промежуток
    #      времени между итерациями и нам пришлось проспать меньше
    #      положенного, чтобы компенсировать это - вот из-за этих трех причин
    #      мы вычислим его вручную, а не примем за коэффициент время,
    #      отведенное нам на сон (хуя себе, как жизненно!)
    #   2. Вычисляем, сколько траффика он успел принять или передать,
    #      заглядываем в базу RADIUS и, если там стоят нулевые значения,
    #      подозреваем о том, что NAS не умеет отдавать аккаунтинговые пакеты
    #      в процессе сессии, снимаем эти данные с интерфейса NAS, на котором
    #      и сидит пользователь...
    #      .*. ВНИМАНИЕ! .*.
    #      Если ваши NAS все же отдают эти данные на RADIUS, обязательно
    #      убедитесь в том, что это происходит чаще, чем эта программа
    #      выполняет процесс тарификации!
    #   3. Вычисляем количество денег, на которые "попадает" пользователь за
    #      работу в промежутке между срабатываниями тарификатора, сверяясь с
    #      его тарифной сеткой
    #   4. Проверяем, можно ли продолжать эту сессию или лучше тупо прибить
    #      ее на хуй

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


        # Сколько времени насидел этот товарищ?

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


        # Сколько октетов он успел насосать?

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


        # Подсчитываем, сколько таньгэ он нам должен

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

        
        # Если стоимость сессии < 0, это означает, что доступ запрещен!
        # В противном случае мы списываем эти таньга с баланса пользователя

        $debug->write(
            DEBUG_DEBUG,
            "$sessions{$session_id}->{'session'}: checking for access grants"
        );

        if ($sessions{$session_id}->{'cost'} < 0) {
            $debug->write(
                DEBUG_DEBUG,
                $sessions{$session_id}->{'session'} . ": access denied!"
            );
            # Чтоб не прибавлялись байтики-то:)
            $sessions{$session_id}->{'cost'} = 0;
            # Хуйачим юзера по башке:)
            seek_and_destroy($sessions{$session_id}->{'session'});
            next;
        }

        # На этом процедуры непосредственно тарификации завершаются.

        # Проверяем баланс пользователя, который раблтает в этой сессии, и
        # его user::session->{'uexpire'}
        # Ахтунг, бля! Если у юзера catty::user->{'udbtr'} возвращает TRUE и
        # при этом catty::user->{'udbtrd'} не ниже текущих даты-времени, то
        # этот юзер имеет право работать в кредит и стрелять в него при выходе
        # в минус не нужно, зато по истечении user::session->{'uexpire'},
        # можешь хуйнуть по нему с удвоенной яростью:)

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


        # Лежачего не бьют! Если RADIUS утверждает, что сессия уже закрыта,
        # повторная тарификация нам не понадобится

        if (timestamp2unixtime($sessions{$session_id}->{'time_stop'}) > 0) {
            $debug->write(
                DEBUG_DEBUG,
                $sessions{$session_id}->{'session'} .
                ": session is down, skipping"
            );
            next;
        }

        # Ну, а если он ёщё живой, подумаем, не ебануть ли его чем-нибудь по
        # головушке буйной

        # Проверяем баланс

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

        # Проверяем, не поэкспайрился ли аккаунт

        if (
            timestamp2unixtime($sessions{$session_id}->{'user'}->{'uexpire'}) <
            timestamp2unixtime($time_now)
        ) {
            $debug->write(DEBUG_INFO, "Account is expired!");
            seek_and_destroy($sessions{$session_id}->{'session'});
            next;
        }

        # Проверяем, не слишком ли много одновременных соединений

        if (
            $sessions{$session_id}->{'user'}->{'uklogins'} <
            scalar(keys(%{$sessions{$session_id}->{'user'}->{'usessions'}}))
        ) {
            $debug->write(DEBUG_INFO, "Too many simultaneous sessions!");
            seek_and_destroy($sessions{$session_id}->{'session'});
            next;
        }

        # Проверяем, не пора ли пиздануть кого-то из "негарантированных"

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

        # Проверяем, все ли, кому положеноно, подвергаются рекламному гипнозу

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

        # Проверяем, не превышены ли ограничения на продолжительность сессии

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


    # Для каждой из активных сессий выполним запись биллинговой информации

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


    # Для каждой из активных сессий проверим, не пошла ли та сессия по пизде

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

            # Производим процесс закрытия интерфейса сессии явным образом,
            # хотя он все равно был бы вызван при уничтожении объекта в памяти.
            # Если в процессе закрытия произойдут какие-либо неполадки, значит,
            # что не все в порядке в датском королевстве

            unless (defined($sessions{$session_id}->close)) {
                $debug->write(
                    DEBUG_ERROR,
                    "Can't catty::session->close(): " .
                    $sessions{$session_id}->{'error'}
                );
                # exit(-1);
            }

            # Вычёркиваем ссылку на сессию из объекта catty::user...

            delete(${$sessions{$session_id}->{'user'}->{'usessions'}}{$session_id});

            # ...и из объекта catty::nas

            delete(${$sessions{$session_id}->{'nas'}->{'sessions'}}{$session_id});

            # Удаляем объект catty::session из памяти; он нам больше не
            # понадобится

            $sessions{$session_id}->DESTROY;

            # Вышвыриваем из кыша
            
            delete($sessions{$session_id});
        }

    }


    # Вычистим из кеша юзеров те записи, для которых не открыто ни одной сессии
    # Если верить документации по perl, объект класса catty::user будет удален
    # из памяти автоматом, как только исчезнут все ссылки на него

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


    # Получаем список открытых сессий из базы catty, чтобы избавиться от
    # мертвечины :)

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


    # Чтобы не отставать от графика, спим ровно столько, сколько необходимо
    # для того, чтоб компенсировать наше отставание от указанного графика.

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
            
    # Теперь, когда тарификация сессий по времени завершена и когда мы
    # проспали необходимое количество времени, мы можем сохранить устевший
    # тайм-стамп перед началом новой итерации, в самом начале которой он будет
    # заменен на более актуальный

    $time_was = $time_now;


# Вот и циклу конец, а кто работал - молодец
# А кто НЕ работал - получит свирепой пизды!

} until ($stop_job);

# Пизды счас получат оставшиеся в живых сессии...

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

# Убиваем PID-файл

$debug->write(DEBUG_DEBUG, "Removing a PID-file");
unless (defined(unlink($conf->{'pid_file'}))) {
    $debug->write(DEBUG_DEBUG, "Can't unlink(): $!");
    # exit(-1);
}

# Остановка NAS-мониторов

$debug->write(DEBUG_DEBUG, "Shutting SNMP-monitors down");
foreach my $nas (keys(%nases)) {
    unless (defined($nases{$nas}->close)) {
        $debug->write(
            DEBUG_ERROR,
            "Can't catty::nas->close(): " . $nases{$nas}->{'error'}
        );
        # exit(-1);
    }

    delete($nases{$nas});       # Удаляем ссылку на NAS из списка
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
    DEBUG_DEBUG, "Disconnecting from MySQL-server at " .
    $conf->{'mysql_r_host'}
);
unless (defined($dbh_r->disconnect)) {
    $debug->write(DEBUG_ERROR, "Can't DBI::db->close(): " . $dbh_r->errstr);
}


# Закрытие интерфейса протоколирования

$debug->write(
    DEBUG_DEBUG, "My last words before I will close logs"
);
unless (defined($debug->close)) {
    warn("Can't debug->close(): $debug->{'error'}");
    # exit(-1);
}


# На свободу с чистой совестью!

exit(my $consience = undef);


# Перехватчики сигналов

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


# Функция создания и записи PID-файла

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


# Функция принудительного закрытия сессии в базе radacct

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

# Охуенно-пиздато-секурная ф-ция вызова прибивалки
# ...да, блять, пиздатее уже просто некуда... :-//

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
