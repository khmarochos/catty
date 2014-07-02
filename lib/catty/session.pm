#
#   $Id: session.pm,v 1.7 2003/12/17 11:56:56 melnik Exp $
#

package catty::session;

use strict;

use Exporter;
use vars qw($VERSION @ISA @EXPORT);

$VERSION            = '0.01';
@ISA                = qw(Exporter);
@EXPORT             = qw();

use FindBin qw($Bin);

use lib "$Bin/../lib";

use timestamp;

use POSIX qw(strftime);


# Проце-дура инициализации объекта, возвращает два скаляра: указатель на
# объект (в случае ошибки - undef) и сообщение об ошибке (в случае отсутствия
# ошибок - undef)

sub new {
    my($class, %argv) = @_;

    # Структура данных класса

    my $self = {
        session         => undef,   # Идентификатор сессии
        user            => undef,   # Объект класса catty::user
        nas             => undef,   # Объект класса catty::nas
        nasport         => undef,   # Номер порта NAS, занятого сессией
        nasmagic        => undef,   # magic-номер сессии на NAS
        csid            => undef,   # Данные АОН
        time_start      => undef,   # Время начала сессии
        time_stop       => undef,   # Время кончала сессии
        time_used       => undef,   # Сколько времени он провисел на линии
        traf_input      => undef,   # Счетчик принятых октетов
        traf_output     => undef,   # Счетчик отправленных октетов
        traf_input_now  => undef,   # Счетчик принятых октетов "взагали"
        traf_output_now => undef,   # Счетчик отправленных октетов "взагали"
        traf_input_was  => undef,   # Предыдущее значение $traf_input_now
        traf_output_was => undef,   # Предыдущее значение $traf_output_now
        advertized      => undef,   # Когда в последний раз запрашивалась реклама?
        last_update     => undef,   # Когда в последний раз обновлялась инфа?
        cost            => undef,   # Стоимость промежутка сессии
        kill_it         => undef,   # Если равен единице - сессию нужно давить
        dbh_c           => undef,   # Объект класса DBI::db для catty
        dbh_r           => undef,   # Объект класса DBI::db для radius
        justfind        => undef,   # Заебал, пояснения ниже!
        time_now        => undef,   # Время начала этой итерации
        error           => undef,   # Сообщение об ошибке
        # Тут уже пошли ссылки на объекты класса DBI::st, пояснения будут ниже
        sth_find_session            => undef,
        sth_create_session          => undef,
        sth_get_session_acct        => undef,
        sth_get_cost                => undef,
        sth_write_acctdata          => undef
    };

    bless($self, $class);

    # Процедура парсинга параметров
    #       -session    => Идентификатор сессии
    #       -user       => Объект класса catty::user
    #       -nas        => Объект класса catty::nas
    #       -nasport    => Номер порта NAS, занятого сессией
    #       -csid       => Данные АОН
    #       -dbh_c      => Объект класса DBI::db для catty
    #       -dbh_r      => Объект класса DBI::db для radius
    #       -justfind   => Если TRUE, можно только отыскать существующую сессию
    #                      в таблице, но создавать новую запрещено

    foreach (keys(%argv)) {
        if (/^-?session$/i) {
            $self->{'session'}  = $argv{$_};
        } elsif (/^-?user$/i) {
            $self->{'user'}     = $argv{$_};
        } elsif (/^-?nas$/i) {
            $self->{'nas'}      = $argv{$_};
        } elsif (/^-?nasport$/i) {
            $self->{'nasport'}  = $argv{$_};
        } elsif (/^-?csid$/i) {
            $self->{'csid'}     = $argv{$_};
        } elsif (/^-dbh_c$/i) {
            $self->{'dbh_c'}    = $argv{$_};
        } elsif (/^-dbh_r$/i) {
            $self->{'dbh_r'}    = $argv{$_};
        } elsif (/^-justfind/i) {
            $self->{'justfind'} = $argv{$_};
        } elsif (/^-time_now/i) {
            $self->{'time_now'} = $argv{$_};
        } else {
            return(undef, "Unknown parameter $_");
        }
    }


    # Подготовим заранее все DBI::st

    # Это для обнаружения сессии и получения значений счетчиков по ее номеру

    $self->{'sth_find_session'} = $self->{'dbh_c'}->prepare(
        "SELECT " .
            "stime_start, " .
            "stime_stop, " .
            "straf_input, " .
            "straf_output " .
        "FROM sessions " .
        "WHERE " .
            "ssession = ?"
    );

    # Это для создания новой записи в таблице sessions

    $self->{'sth_create_session'} = $self->{'dbh_c'}->prepare(
        "INSERT INTO sessions " .
        "SET " .
            "ssession = ?, " .
            "suser = ?, " .
            "snas = ?, " .
            "snasport = ?, " .
            "scsid = ?, " .
            "spack = ?"
    );

    # Получение данных о сессии из таблицы FreeRADIUS

    $self->{'sth_get_session_acct'}= $self->{'dbh_r'}->prepare(
        "SELECT " .
            "AcctStartTime, " .
            "AcctStopTime, " .
            "AcctOutputOctets, " .
            "AcctInputOctets, " .
            "cattyAdvertized " .
        "FROM radacct " .
        "WHERE " .
            "AcctUniqueId = ?"
    );

    # Получение данных о стоимости

    $self->{'sth_get_cost'} = $self->{'dbh_c'}->prepare(
        "SELECT " .
            "cmoment, " .
            "ctime, " .
            "ctimecb, " .
            "ctimecbd, " .
            "cinput, " .
            "cinputcb, " .
            "cinputcbd, " .
            "coutput, " .
            "coutputcb, " .
            "coutputcbd " .
        "FROM costs " .
        "WHERE " .
            "ccode = ? " .
        "ORDER BY " .
            "corder"
    );

    # Вот этот - для записи аккаунтинговой информации в таблицу sessions

    $self->{'sth_write_acctdata'} = $self->{'dbh_c'}->prepare(
        "UPDATE sessions " .
        "SET " .
            "stime_start = ?, " .
            "stime_stop = ?, " .
            "straf_input = straf_input + ?, " .
            "straf_output = straf_output + ?, " .
            "scost = scost + ? " .
        "WHERE " .
            "ssession = ?"
    );


    # Проверим, всё ли правильно с этой сессией, действительно ли присутствует
    # она на этом NAS и заодно получим её magic-номер

    if ($self->{'nas'}->{'nntbc'}) {
        $self->{'nasmagic'} = $self->{'nas'}->get_magic(
            $self->{'nasport'},
            $self->{'time_now'}
        );
        unless (defined($self->{'nasmagic'})) {
            return(
                undef,
                "Can't catty::nas->get_magic(): " . $self->{'nas'}->{'error'}
            );
        }
    }


    # Откроем новую запись в таблице сессий

    unless (defined($self->db_new)) {
        return(
            undef,
            "Can't catty::session->db_new(): " . $self->{'error'}
        );
    }

    return($self, undef);
}


# Создание новой записи в учетной таблице или нахождение записи о сессии
# (в случае, если сессия была оставлена открытой)

sub db_new {
    my ($self) = @_;

    unless (
        defined($self->{'sth_find_session'}->execute($self->{'session'}))
    ) {
        $self->{'error'} =
            "Can't DBI::st->execute(): " . $self->{'dbh_c'}->errstr;
        return(undef);
    }

    (
        $self->{'time_start'},
        $self->{'time_stop'},
        $self->{'traf_input_was'},
        $self->{'traf_output_was'}
    ) = $self->{'sth_find_session'}->fetchrow_array;

    unless (defined($self->{'sth_find_session'}->finish)) {
        $self->{'error'} =
            "Can't DBI::st->finish(): " . $self->{'dbh_c'}->errstr;
        return(undef);
    }

    if (
        defined($self->{'time_start'}) ||
        defined($self->{'time_stop'}) ||
        defined($self->{'traf_input_was'}) ||
        defined($self->{'traf_output_was'})
    ) {
        return(0);
    }

    if ($self->{'justfind'}) {
        $self->{'error'} = "Can't justfind $self->{'session'} in database";
        return(undef);
    }

    unless (defined($self->{'sth_create_session'}->execute(
        $self->{'session'},
        $self->{'user'}->{'uid'},
        $self->{'nas'}->{'nid'},
        $self->{'nasport'},
        $self->{'csid'},
        $self->{'user'}->{'uktid'}
    ))) {
        $self->{'error'} =
            "Can't DBI::st->execute(): " . $self->{'dbh_c'}->errstr;
        return(undef);
    }

    return(0);
}


# Опрос RADIUS на предмет учетных данных: времени начала и окончания
# сессии и количество прошедших по линку октетов

sub query_radius {
    my ($self, $time_now) = @_;

    # Получение учетной информации о заданной сессии

    unless (
        defined($self->{'sth_get_session_acct'}->execute($self->{'session'}))
    ) {
        $self->{'error'} =
            "Can't DBI::db->execute(): " . $self->{'dbh_r'}->errstr;
        return(undef);
    }

    # В зависимости от того, умеет ли железяка NAS отдавать промежуточную
    # информацию о скачанном трафике по RADIUS, получаем или не получаем
    # данные об оном из RADIUS (если не умеет - не получаем и забираем
    # их потом по SNMP).

    if ($self->{'nas'}->{'nsrac'}) {
        (
            $self->{'time_start'},
            $self->{'time_stop'},
            $self->{'traf_input_now'},
            $self->{'traf_output_now'},
            $self->{'advertized'}
        ) = $self->{'sth_get_session_acct'}->fetchrow_array;
    } else {
        (
            $self->{'time_start'},
            $self->{'time_stop'},
            undef,
            undef,
            $self->{'advertized'}
        ) = $self->{'sth_get_session_acct'}->fetchrow_array;
    }
    unless (defined($self->{'sth_get_session_acct'}->finish)) {
        $self->{'error'} =
            "Can't DBI::db->finish(): " . $self->{'dbh_r'}->errstr;
        return(undef);
    }

    # Если ничего не вернулось, вываливаемся в ужэсе

    unless (
        defined($self->{'time_start'}) &&
        defined($self->{'time_stop'})
    ) {
        $self->{'error'} = "Can't find session data in SQL";
        return(undef);
    }

    $self->{'last_update'} = $time_now;

    return(0);

}


# Процедура подсчета времени, проведенного пользователем он-лайн между
# первым и вторым тайм-стампами.
# На входе требует $time_now (текущее время) и $time_was (время предыдущего
# прогона тарификатора).
# Возвращает нулевое значение или undef, в случае ошибки
# Результат вычислений помещает в $self->{'time_used'}.

sub count_time {
    my ($self, $time_now, $time_was) = @_;

    # Если данные от RADIUS безнадежно устарели - ругаемся

    if ($time_now ne $self->{'last_update'}) {
        $self->{'error'} =
            "I didn't received any information from RADIUS, " .
            "last updated " . $self->{'last_update'};
        return(undef);
    }

    # Хитросракое вычисление.
    # Количество времени, проведенного он-лайн за прошедший промежуток
    # времени равно разнице X - Y, где X равен времени останова сессии
    # (или текущему времени, если сессия еще не завершилась), а Y равен
    # времени предыдущей итерации (или времени начала сессии, если эта
    # сессия началась уже после отработки предыдущей итерании).

    $self->{'time_used'} =
        (
            (
                timestamp2unixtime($self->{'time_stop'}) >
                0
            ) ?
            timestamp2unixtime($self->{'time_stop'}) :
            timestamp2unixtime($time_now)
        ) - (
            (
                timestamp2unixtime($self->{'time_start'}) >
                timestamp2unixtime($time_was)
            ) ?
            timestamp2unixtime($self->{'time_start'}) :
            timestamp2unixtime($time_was)
        );

    return(0);
}


# Процедура подсчета количества октетов, принятых и переданных пользлователем
# с момента предыдущего вызова (дельты, мол, вычисляем сразу)

sub count_traffic {
    my ($self, $time_now) = @_;

    # Если данные от RADIUS безнадежно устарели - ругаемся

    if ($time_now ne $self->{'last_update'}) {
        $self->{'error'} =
            "I didn't received any information from RADIUS, " .
            "last updated " . $self->{'last_update'};
        return(undef)
    }

    # Если $self->{'nas'}->{'nsrac'} возвращает TRUE, это означает, что NAS
    # умеет самостоятельно сообщать учетную информацию RADIUS в процессе
    # работы, мы будем брать данные непосредственно оттуда, а не дергать
    # регулярно несчастный NAS с SNMP-расспросами
    # Следует обратить внимание на то, что мы не станем дергать NAS в том
    # случае, если эта сессия уже была закрыта, чтобы случайно не считать
    # данные о траффике с другой сессии, которая уже успела занять этот вот
    # интерфейс!

    if (
        (! $self->{'nas'}->{'nsrac'}) &&
        (! (timestamp2unixtime($self->{'time_stop'}) > 0))
    ) {

        (
            $self->{'traf_input_now'},
            $self->{'traf_output_now'}
        ) = $self->{'nas'}->get_octets($self->{'nasport'}, $time_now);
        unless (
            defined($self->{'traf_input_now'}) &&
            defined($self->{'traf_output_now'})
        ) {
            $self->{'traf_input_now'}   = $self->{'traf_input_was'};
            $self->{'traf_output_now'}  = $self->{'traf_output_was'};
            $self->{'error'} =
                "Can't catty::nas->get_octets(): " .
                $self->{'nas'}->{'error'};
            return(undef);
        }

        $self->{'traf_input_was'} =
            ($self->{'traf_input_was'} > 0) ?
                $self->{'traf_input_was'} :
                $self->{'traf_input_now'};
        $self->{'traf_output_was'} =
            ($self->{'traf_output_was'} > 0) ?
                $self->{'traf_output_was'} :
                $self->{'traf_output_now'};
    }

    # Загоняем дельты в переменные счетчиков; на основе именно дельт мы и будем
    # далее проводить тарификацию.

    $self->{'traf_input'} =
        ($self->{'traf_input_now'} >= $self->{'traf_input_was'}) ?
            ($self->{'traf_input_now'} - $self->{'traf_input_was'}) :
            ($self->{'traf_input_now'});
    $self->{'traf_input_was'} = $self->{'traf_input_now'};
    $self->{'traf_output'} =
        ($self->{'traf_output_now'} >= $self->{'traf_output_was'}) ?
            ($self->{'traf_output_now'} - $self->{'traf_output_was'}) :
            ($self->{'traf_output_now'});
    $self->{'traf_output_was'} = $self->{'traf_output_now'};

    # МАМА, ТЫ РОДИЛА УЁБКА!!! (2004-02-26)

    return(0);
}


# Процедура подсчета стоимости потребленных пользователем услуг в зависимости
# от тарифного плана пользователя, времени, проведенном ним он-лайн и траффика,
# который он принял и передал с момента последнего тарификационного прогона.
# Проверяет, стоит ли выбросить пользователя (если в данный момент его
# тарифная схема не предусматривает разрешения доступа к сети).
# Записывает результат вычислений в $self->{'cost'}.
# Возвращает 0 или undef в случае ошибки.
# На входе требует $time_now.

sub count_cost {
    my ($self, $time_now) = @_;

    # Если данные от RADIUS безнадежно устарели - ругаемся

    if ($time_now ne $self->{'last_update'}) {
        $self->{'error'} =
            "I didn't received any information from RADIUS, " .
            "last updated " . $self->{'last_update'};
        return(undef);
    }

    # Получение списка промежутков данного тарифного плана.

    unless (defined($self->{'sth_get_cost'}->execute(
        $self->{'user'}->{'upack'},
    ))) {
        $self->{'error'} =
            "Can't DBI::st->execute(): " . $self->{'dbh_c'}->errstr;
        return(undef);
    }

    # Крутим цикл, чтобы получить все записи об этом тарифном пакете и найти
    # промежуток, подходящий моменту.

    my $db_cmoment;
    my $db_ctime;
    my $db_ctimecb;
    my $db_ctimecbd;
    my $db_cinput;
    my $db_cinputcb;
    my $db_cinputcbd;
    my $db_coutput;
    my $db_coutputcb;
    my $db_coutputcbd;
    
    CHECK_MOMENT_LOOP:
    while ((
        $db_cmoment,
        $db_ctime,
        $db_ctimecb,
        $db_ctimecbd,
        $db_cinput,
        $db_cinputcb,
        $db_cinputcbd,
        $db_coutput,
        $db_coutputcb,
        $db_coutputcbd
    ) =
        $self->{'sth_get_cost'}->fetchrow_array
    ) {
        foreach my $moment (split(/,/, $db_cmoment)) {
            my $valid_moment = $self->check_moment(
                $moment,
                (localtime(timestamp2unixtime($time_now)))[2],
                (localtime(timestamp2unixtime($time_now)))[6]
            );
            unless (defined($valid_moment)) {
                $self->{'error'} =
                    "Can't catty::session::check_moment(): " .
                    $self->{'error'};
                return(undef);
            }
            if ($valid_moment) {
                last CHECK_MOMENT_LOOP;
            }
        }

        # Чтобы не наебаться на оставшемся значении в $db_cmoment, которое
        # осталось после прокрутки всех циклов при ненахождении нужного
        # тарифного пакета, андефим эту переменную.
        
        $db_cmoment = undef;
    }

    unless (defined($self->{'sth_get_cost'}->finish)) {
        $self->{'error'} =
            "Can't DBI::st->finish(): " . $self->{'dbh_c'}->errstr;
        return(undef);
    }

    # Если какое-то из трех значений возвращает undef, это значит, что в
    # датском королевстве не все в порядке и что с таблицей тарифных сеток
    # у нас определенно есть проблемы

    unless (
        defined($db_cmoment)    &&
        defined($db_ctime)      &&
        defined($db_ctimecb)    &&
        defined($db_ctimecbd)   &&
        defined($db_cinput)     &&
        defined($db_cinputcb)   &&
        defined($db_cinputcbd)  &&
        defined($db_coutput)    &&
        defined($db_coutputcb)  &&
        defined($db_coutputcbd)
    ) {
        $self->{'error'} =
            "Something strange has been found in costs table, " .
                "one or more of values is undefined: " .
                "cmoment = $db_cmoment, " .
                "ctime = $db_ctime, " .
                "ctimecb = $db_ctimecb, " .
                "ctimecbd = $db_ctimecbd, " .
                "cinput = $db_cinput, " .
                "cinputcb = $db_cinputcb, " .
                "cinputcbd = $db_cinputcbd, " .
                "coutput = $db_coutput, " .
                "coutputcb = $db_coutputcb, " .
                "coutputcbd = $db_coutputcbd";
        return(undef);
    }

    # Если пользователь подключился на "call-back", $db_c[...] получает
    # значения из $db_c[...]cb, если он при этом ещё и "скидочник", он
    # получает значения из $db_c[...]cbd

    my $real_ctime;
    my $real_cinput;
    my $real_coutput;

    if ($self->{'csid'} =~ /\+$/) {
        if (timestamp2unixtime($self->{'user'}->{'uexpire'}) < 1095195600) {
            $real_ctime     = $db_ctimecbd;
            $real_cinput    = $db_cinputcbd;
            $real_coutput   = $db_coutputcbd;
        } else {
            $real_ctime     = $db_ctimecb;
            $real_cinput    = $db_cinputcb;
            $real_coutput   = $db_coutputcb;
        }
    } else {
        $real_ctime         = $db_ctime;
        $real_cinput        = $db_cinput;
        $real_coutput       = $db_coutput;
    }

    # Если какое-то из трех значений тарификационной сетки возвращает
    # отрицательное значение, это означает, что в настоящее время доступ
    # запрещен и пользователя следует выбросить нахуй

    if (
        ($real_ctime    < 0) ||
        ($real_cinput   < 0) ||
        ($real_coutput  < 0)
    ) {
        $self->{'kill_it'} = 1;
    }

    $self->{'cost'} =
        ($real_ctime    * ($self->{'time_used'} / 3600)) +
        ($real_cinput   * ($self->{'traf_input'} / 1048576)) +
        ($real_coutput  * ($self->{'traf_output'} / 1048576));

    return(0);
}


# Процедура проверки части cmoment на соответствие текущей дате и времени.
# Получает на входе строковое $moment (часть costs.cmoment, проверяемая на
# данный момент), числовое $dow (день недели) и числовое $hod (час суток).
# Возвращает 1 или 0. Или, конечно, undef в случае хуйни.

sub check_moment {
    my ($self, $moment, $hod, $dow) = @_;

    my $dow_b;
    my $dow_e;
    my $hod_b;
    my $hod_e;

    # Будем считать воскресенье седьмым днём, а не нулевым.

    $dow = 7 if ($dow == 0);

    # Анализируем строку на соответствие шаблону.
    
    if ($moment =~ /^([a-z]{1,2})(-([a-z]{1,2}))?([0-9]{1,2})(-([0-9]{1,2}))?$/i) {

        # Получение числового промежутка дней (1-7) из первой части
        # строкового промежутка дней (Al, Wk, Wd, ...).
    
        ($dow_b, $dow_e) = $self->convert_days($1);

        if (defined($dow_e) && defined($3)) {
        
            # Если функция вернула два значения вместо одного, это означает,
            # что в первой части строкового промежутка был задан общий
            # промежуток и его значение оказалось равным "Al", "Wk" или "Wd".
            # Если при этом зачем-то было задана вторая часть строкового
            # промежутка дней, это означает, что у какого-то долбоёба совсем
            # искривились руки.

            $self->{'error'} = "Lame cmoment: $moment";
            return(undef);

        } elsif (! defined($dow_e)) {

            # Если функция вернула только одно значение, это означает, что нам
            # следует обработать вторую половину строкового промежутка, ибо в
            # первой половине никаких намёков на конец промежутка обнаружено
            # не было.

            if (defined($3)) {

                # Если при этом в нашем строковом промежутке присутствует
                # вторая половина значения, мы проанализируем и её.

                my ($dow_e1, $dow_e2) = $self->convert_days($3);

                if (defined($dow_e2)) {

                    # Если вторая половина вернула почему-то два значения,
                    # это уж точно какая-то хуйня, поскольку запись типа
                    # "Fr-Al" выглядит как-то совсем неадекватно.
                
                    $self->{'error'} = "Lame cmoment: $moment";
                    return(undef);

                }

                $dow_e = $dow_e1;

            } else {

                # В противном же случае конец промежутка равен его началу.

                $dow_e = $dow_b;

            }
        }

        # Если же мы так и не выяснили значения промежутка дней недели, это
        # означает только то, что произошла некая ошибка и нам уместно было бы
        # произнести магическое заклинание "ёб-твою-мать" и затем нецензурно
        # выругаться.
        
        unless (defined($dow_b) && defined($dow_e)) {
            $self->{'error'} =
                "Can't catty::session::convert_days(): " . $self->{'error'};
            return(undef);
        }

        # Приступаем к выяснению промежутка часов и тут же получаем значение
        # начала промежутка.

        $hod_b = $4;

        # Если был задан конец промежутка, принимаем его за истину, если же
        # его обнаружить не удалось, конец промежутка равен его началу с
        # инкрементированием.

        if (defined($6)) {
            $hod_e = $6;
        } else {
            $hod_e = $hod_b + 1;
        }

        # Проверяем валидность этого промежутка часов.

        if ($hod_b == $hod_e) {

            # Они не могут быть равны, поскольку суточный промежуток задаётся
            # выражением "0-24", а не "0-0" или "13-13".
        
            $self->{'error'} = "Lame cmoment: $moment";
            return(undef);

        } elsif (
            ($hod_b < 0)    ||
            ($hod_b > 23)   ||
            ($hod_e < 1)    ||
            ($hod_e > 24) 
        ) {

            # Начало не может быть меньше 0 или больше 23, а конец не может
            # быть меньше 1 и больше 24.

            $self->{'error'} = "Lame cmoment: $moment";
            return(undef);
        
        }
        
        # Если мы так и не выяснили значение промежутка часов, уходим.
        
        if (! (defined($hod_b) && defined($hod_e))) {
            $self->{'error'} = "Lame cmoment: $moment";
            return(undef);
        }
        
    } else {

        # Если строка не соответствует шаблону, пусть тот, кто её составил,
        # засунет её себе в задницу.
    
        $self->{'error'} = "Lame cmoment: $moment";
        return(undef);

    }

    # Собственно, проверка попадания текущего момента в промежуток.

    if (
        (
         ((($dow_b) <= ($dow_e)) && (($dow >= $dow_b) && ($dow <= $dow_e))) ||
         ((($dow_b) >  ($dow_e)) && (($dow >= $dow_b) || ($dow <= $dow_e)))
        ) && (
         ((($hod_b) <= ($hod_e)) && (($hod >= $hod_b) && ($hod <  $hod_e))) ||
         ((($hod_b) >  ($hod_e)) && (($hod >= $hod_b) || ($hod <  $hod_e)))
        )
    ) {
        return(1)
    } else {
        return(0)
    }

}


# Процедура преобразования дней недель из слов в числа.

sub convert_days {
    my ($self, $dow) = @_;

    if ($dow =~ /^Al$/i) {
        return(1, 7);
    } elsif ($dow =~ /^Wk$/i) {
        return(1, 5);
    } elsif ($dow =~ /^Wd$/i) {
        return(6, 7);
    } elsif ($dow =~ /^Mo$/i) {
        return(1, undef);
    } elsif ($dow =~ /^Tu$/i) {
        return(2, undef);
    } elsif ($dow =~ /^We$/i) {
        return(3, undef);
    } elsif ($dow =~ /^Th$/i) {
        return(4, undef);
    } elsif ($dow =~ /^Fr$/i) {
        return(5, undef);
    } elsif ($dow =~ /^Sa$/i) {
        return(6, undef);
    } elsif ($dow =~ /^Su$/i) {
        return(7, undef);
    } else {
        $self->{'error'} = "Unrecognized day: $dow";
        return(undef, undef);
    }
}


# Процедура записи учетной информации
# $cost нужен нам для того, чтобы удостовериться в том, что мы должны не
# просто записать информацию о сессии, но и прибавить промежуточное число
# к полю стоимости. Если же $cost нам при вызове не дадут, это означает то,
# что сессию просто хотят закрыть, а это происходит и при выходе из
# тарификационного цикла (в catty::session->close()) и при завершении
# программы (в catty::session->DESTROY()).

sub write_acctdata {
    my ($self, $cost) = @_;

    unless (defined($self->{'sth_write_acctdata'}->execute(
        $self->{'time_start'},
        $self->{'time_stop'},
        # Если там undef'ы, ставим 0, иначе SQL пошлет нас на хуй
        (defined($self->{'traf_input'})  ? $self->{'traf_input'}  : 0),
        (defined($self->{'traf_output'}) ? $self->{'traf_output'} : 0),
        (defined($cost)                  ? $self->{'cost'}        : 0),
        # А вот это уже undef'ом быть не должно...
        $self->{'session'}
    ))) {
        $self->{'error'} =
            "Can't DBI::st->execute(): " . $self->{'dbh_c'}->errstr;
        return(undef);
    }

    return(0);
}


# Завершение сессии (может быть принудительным)

sub close {
    my ($self) = @_;

    # Если сессия раззявлена, зазяливаем ее текущим временем и производим
    # запись в базу данных

    unless ($self->{'time_stop'} > 0) {
        $self->{'time_stop'} = (
            defined($self->{'last_update'}) ?
                $self->{'last_update'} :
                strftime("%Y-%m-%d %H:%M:%S", localtime)
        );
        unless (defined($self->write_acctdata)) {
            $self->{'error'} =
                "Can't catty::session->write_acctdata(): " .
                $self->{'error'};
            return(undef);
        }
    }

#   $self->{'session'} = undef;

    return(0);
}


# Пиздец объекту

sub DESTROY {
    my ($self) = @_;

    if (defined($self->{'session'})) {
        $self->close();
    }
}


1;
