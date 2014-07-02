#
#   $Id: nas.pm,v 1.2 2003/04/19 20:38:14 melnik Exp $
#

package catty::nas;

use strict;

use Exporter;
use vars qw($VERSION @ISA @EXPORT);

$VERSION            = '0.01';
@ISA                = qw(Exporter);
@EXPORT             = qw();

use FindBin qw($Bin);
use Net::SNMP qw(:ALL);


# Пиздец, сегодня (среда, 12 мая 2004 г. 14:25:13 (EEST)) я перепишу всю эту
# поебень по-новой! :-E


# Проце-дура инициализации объекта, возвращает два скаляра: указатель на
# объект (в случае ошибки - undef) и сообщение об ошибке (в случае отсутствия
# ошибок - undef)

sub new {
    my($class, %argv) = @_;

    # Структура данных класса
    
    my $self = {
        nid         => undef,   # Индикатор записи о NAS
        naddr       => undef,   # IP-адрес NAS
        ncomm       => undef,   # RW-соёбщество (SNMP) NAS
        nsrac       => undef,   # S.upports R.adius AC.counting
        nntbc       => undef,   # N.eed T.o B.e C.hecked
        ntype       => undef,   # Тип NAS
        nports      => undef,   # Количество портов
        snmp        => undef,   # Объект SNMP-сессии
        magicd      => undef,   # Данные таблицы magic-номеров
        magict      => undef,   # Время последнего обновления таблицы magicd
        ifindexd    => undef,   # Данные таблицы ifindex-номеров
        ifindext    => undef,   # Время последнего обновления таблицы ifindexd
        sessions    => undef,   # Список сессий для этого NAS
        error       => undef    # Сообщение об ошибке
    };
    
    bless($self, $class);

    # Парсинг параметров:
    #       -nid        => Идентификатор записи об этом NAS
    #       -naddr      => IP-адрес NAS
    #       -ncomm      => RW-соёбщество (SNMP) NAS
    #       -nsrac      => S.upports R.adius AC.counting
    #       -nntbc      => N.eed T.o B.e C.hecked
    #       -ntype      => Тип NAS
    #       -nports     => Количество портов
    
    foreach (keys(%argv)) {
        if (/^-?nid$/i) {
            $self->{'nid'}          = $argv{$_};
        } elsif (/^-?naddr$/i) {
            $self->{'naddr'}        = $argv{$_};
        } elsif (/^-?ncomm$/i) {
            $self->{'ncomm'}        = $argv{$_};
        } elsif (/^-?nsrac$/i)  {
            $self->{'nsrac'}        = $argv{$_};
        } elsif (/^-?nntbc$/i)  {
            $self->{'nntbc'}        = $argv{$_};
        } elsif (/^-?ntype$/i)  {
            $self->{'ntype'}        = $argv{$_};
        } elsif (/^-?nports$/i)  {
            $self->{'nports'}       = $argv{$_};
        } else {
            return(undef, "Unknown parameter $_");
        }
    }

    # Открываем SNMP-сессию
    
    unless (defined($self->open)) {
        return(undef, "Can't catty::nas->open(): " . $self->{'error'});
    }

    return($self, undef);
}


# Процедура открытия SNMP-сессий
# Собственно, комментировать просто нечего; сессия открывается при помощи
# библиотеки Net::SNMP, посему все следует из `perldoc Net::SNMP`

sub open {
    my ($self) = @_;

    my ($snmp_object, $snmp_error) = Net::SNMP->session(
        -hostname       => $self->{'naddr'},
        -community      => $self->{'ncomm'},
        -version        => 'SNMPv1'
    );

    unless (defined($snmp_object)) {
        $self->{'error'} = "Can't Net::SNMP->session(): $snmp_error";
        return(undef);
    }

    $self->{'snmp'} = $snmp_object;

    return($self->{'snmp'});
}


# Процедура снятия информации о прошедшем по интерфейсу NAS траффике
# При вызове ей следует задать номер порта, c которого нам необходимо
# снять статистику, на выходе она возвращает пару значений: IfOutOctets
# и IfInOctets (с точки зрения NAS "out" - это то, что юзер ПРИНЯЛ, а
# "in" - это то, что он передал, на это следует обратить внимание!)

sub get_octets {
    my ($self, $ifname, $time_now) = @_;

    if (
        ($self->{'ntype'} eq 'cisco5300') ||
        ($self->{'ntype'} eq 'intercom') ||
        ($self->{'ntype'} eq 'netserver')
    ) {

        # Действия для Cisco5300, сервера доступа Intercom
        # и для USR NetServer...

        my $ifindex = $self->get_ifindex($ifname, $time_now);
        unless (defined($ifindex)) {
            $self->{'error'} =
                "Can't catty::nas->get_ifindex(): " . $self->{'error'};
            return(undef, undef);
        }

        my $snmp_responce = $self->{'snmp'}->get_request(
            ".1.3.6.1.2.1.2.2.1.10." . $ifindex,
            ".1.3.6.1.2.1.2.2.1.16." . $ifindex
        );
        unless (defined($snmp_responce)) {
            $self->{'error'} =
                "Can't Net::SNMP->get_request(): " . $self->{'snmp'}->error;
            return(undef, undef);
        }
        return(values(%{$snmp_responce}));

    } else {

        $self->{'error'} = "Unsupported NAS type " . $self->{'ntype'};
        return(undef, undef);

    }
}


# Процедура терминации сессии по заданному имени порта
# При вызове требует имя порта и на выходе возвращает undef в случае ошибки

sub terminate {
    my ($self, $ifname) = @_;

    if ($self->{'ntype'} eq 'cisco5300') {

        # Действия для Cisco5300...

        my $portnumber = $ifname;
        if ($portnumber !~ s/^Async(\d+)$/\1/) {
            $self->{'error'} = "Unsupported port type or invalid port name: $ifname";
            return(undef);
        }

        my $snmp_responce = $self->{'snmp'}->set_request (
            ".1.3.6.1.4.1.9.2.9.10.0", INTEGER, $portnumber
        );
        unless (defined($snmp_responce)) {
            $self->{'error'} =
                "Can't Net::SNMP->set_request(): " . $self->{'snmp'}->error;
            return(undef);
        }

    } elsif ($self->{'ntype'} eq 'intercom') {

        # Действия для сервера доступа Intercom...

        my $new_pid = open(TERMINATOR_INTERCOM, '|-');

        if (! defined($new_pid)) {

            $self->{'error'} = "Can't fork(): $!";
            return(undef);

        } elsif ($new_pid > 0) {

            print(TERMINATOR_INTERCOM "$self->{'naddr'}:$ifname\n");

            unless (close(TERMINATOR_INTERCOM)) {
                $self->{'error'} = "Can't close(): $!";
                return(undef);
            }
        
        } else {

            unless (exec($Bin . '/../bin/terminator_intercom.pl')) {
                die("Can't exec(): $!");
            }

        }

    } elsif ($self->{'ntype'} eq 'netserver') {

        # Действия для USR NetServer...

        my $portnumber = $ifname;
        if ($portnumber !~ s/^Async(\d+)$/\1/) {
            $self->{'error'} = "Unsupported port type or invalid port name: $ifname";
            return(undef);
        }

        my $snmp_responce = $self->{'snmp'}->set_request (
            ".1.3.6.1.2.1.2.2.1.7.$portnumber", INTEGER, 2
        );
        unless (defined($snmp_responce)) {
            $self->{'error'} =
                "Can't Net::SNMP->set_request(): " . $self->{'snmp'}->error;
            return(undef);
        }

        sleep(3);

        my $snmp_responce = $self->{'snmp'}->set_request (
            ".1.3.6.1.2.1.2.2.1.7.$portnumber", INTEGER, 1
        );
        unless (defined($snmp_responce)) {
            $self->{'error'} =
                "Can't Net::SNMP->set_request(): " . $self->{'snmp'}->error;
            return(undef);
        }

    } else {

        $self->{'error'} = "Unsupported NAS type " . $self->{'ntype'};
        return(undef);

    }
}


# Процедура получения magic-номера сессии

sub get_magic {
    my ($self, $ifname, $time_now) = @_;

    if (
        ($self->{'ntype'} eq 'cisco5300') ||
        ($self->{'ntype'} eq 'intercom')
    ) {

        # Действия для Cisco5300 и сервера доступа Intercom...

        my $portnumber = $ifname;
        if ($portnumber !~ s/^Async(\d+)$/\1/) {
            $self->{'error'} = "Unsupported port type or invalid port name: $ifname";
            return(undef);
        }

        if ($self->{'magict'} ne $time_now) {
            $self->{'magict'} = $time_now;
            $self->{'magicd'} = $self->{'snmp'}->get_table(
                '.1.3.6.1.4.1.9.10.19.1.3.1.1.14'
            );
        	unless (defined($self->{'magicd'})) {
    	        $self->{'error'} =
    	            "Can't Net::SNMP->get_table(): " . $self->{'snmp'}->error;
        	    return(undef);
    	    }
        }
	
    	my $magic;
	    foreach my $connection (keys(%{$self->{'magicd'}})) {
	        if (${$self->{'magicd'}}{$connection} eq $portnumber) {
	            $magic = $connection;
	            $magic =~ s/^\.1\.3\.6\.1\.4\.1\.9\.10\.19\.1\.3\.1\.1\.14\.(\d+)\.0$/$1/;
    	    }
	    }
        unless (defined($magic)) {
	        $self->{'error'} = "Can't find magic for $ifname";
        }
	    return($magic);

    } elsif ($self->{'ntype'} eq 'netserver') {

        # Действия для USR NetServer...

        my $portnumber = $ifname;
        if ($portnumber !~ s/^Async(\d+)$/\1/) {
            $self->{'error'} = "Unsupported port type or invalid port name: $ifname";
            return(undef);
        }

        if ($self->{'magict'} ne $time_now) {
            $self->{'magict'} = $time_now;
            $self->{'magicd'} = $self->{'snmp'}->get_table(
                '.1.3.6.1.4.1.429.4.10.1.1.19'
            );
        	unless (defined($self->{'magicd'})) {
    	        $self->{'error'} =
    	            "Can't Net::SNMP->get_table(): " . $self->{'snmp'}->error;
        	    return(undef);
    	    }
        }
	
    	my $magic = ${$self->{'magicd'}}{".1.3.6.1.4.1.429.4.10.1.1.19.$portnumber"};
        unless (defined($magic)) {
	        $self->{'error'} = "Can't find magic for Async$ifname";
        }
	    return($magic);

    } else {

        $self->{'error'} = "Unsupported NAS type " . $self->{'ntype'};
        return(undef);

    }
}


# Процедура проверки magic-номера сессии

sub check_magic {
    my ($self, $ifname, $magic) = @_;

    if (
        ($self->{'ntype'} eq 'cisco5300') ||
        ($self->{'ntype'} eq 'intercom')
    ) {

        # Действия для Cisco5300 и сервера доступа Intercom...

        my $portnumber = $ifname;
        if ($portnumber !~ s/^Async(\d+)$/\1/) {
            $self->{'error'} = "Unsupported port type or invalid port name: $ifname";
            return(undef);
        }

        my $new_port = $self->{'snmp'}->get_request(
            ".1.3.6.1.4.1.9.10.19.1.3.1.1.14.$magic.0"
        );
    	unless (defined($new_port)) {
	        $self->{'error'} =
	            "Can't Net::SNMP->get_table(): " . $self->{'snmp'}->error;
    	    return(undef);
	    }
	
        $new_port = ${$new_port}{".1.3.6.1.4.1.9.10.19.1.3.1.1.14.$magic.0"};
        if ($new_port eq $portnumber) {
            return(1);
        } else {
            return(0);
        }

    } elsif ($self->{'ntype'} eq 'netserver') {

        # Действия для USR NetServer...

        my $portnumber = $ifname;
        if ($portnumber !~ s/^Async(\d+)$/\1/) {
            $self->{'error'} = "Unsupported port type or invalid port name: $ifname";
            return(undef);
        }

        my $new_magic = $self->{'snmp'}->get_request(
            ".1.3.6.1.4.1.429.4.10.1.1.19.$portnumber"
        );
    	unless (defined($new_magic)) {
	        $self->{'error'} =
	            "Can't Net::SNMP->get_table(): " . $self->{'snmp'}->error;
    	    return(undef);
	    }
	
        $new_magic = ${$new_magic}{".1.3.6.1.4.1.429.4.10.1.1.19.$portnumber"};
        if ($new_magic eq $magic) {
            return(1);
        } else {
            return(0);
        }

    } else {

        $self->{'error'} = "Unsupported NAS type " . $self->{'ntype'};
        return(undef);

    }
}


# Процедура получения snmp-индекса интерфейса

sub get_ifindex {
    my ($self, $ifname, $time_now) = @_;

    if ($self->{'ntype'} eq 'cisco5300') {

        # Действия для Cisco5300...
       
        my $portnumber = $ifname;
        if ($portnumber !~ s/^Async(\d+)$/\1/) {
            $self->{'error'} = "Unsupported port type or invalid port name: $ifname";
            return(undef);
        }

        if ($self->{'ifindext'} ne $time_now) {
            $self->{'ifindext'} = $time_now;
    	    $self->{'ifindexd'} = $self->{'snmp'}->get_table(
                '.1.3.6.1.2.1.2.2.1.2'
            );
	        unless (defined($self->{'ifindexd'})) {
	            $self->{'error'} =
    	            "Can't Net::SNMP->get_table(): " . $self->{'snmp'}->error;
	            return(undef);
    	    }
        }
	
	    my $ifindex;
	    foreach my $iface (keys(%{$self->{'ifindexd'}})) {
	        if (${$self->{'ifindexd'}}{$iface} eq $portnumber) {
	            $ifindex = $iface;
	            $ifindex =~ s/^\.1\.3\.6\.1\.2\.1\.2\.2\.1\.2\.(\d+)$/$1/;
	        }
	    }
	    unless (defined($ifindex)) {
	        $self->{'error'} = "Can't find ifindex for $ifname";
	    }
	    return($ifindex);

    } elsif ($self->{'ntype'} eq 'netserver') {

        # Действия для USR NetServer
       
        my $portnumber = $ifname;
        if ($portnumber !~ s/^Async(\d+)$/\1/) {
            $self->{'error'} = "Unsupported port type or invalid port name: $ifname";
            return(undef);
        }

	    return($portnumber);

    } else {

        $self->{'error'} = "Unsupported NAS type " . $self->{'ntype'};
        return(undef);

    }
}


# Процедура закрытия SNMP-сессий, проста до безобразия, как и процедура
# открытия.

sub close {
    my ($self) = @_;

    $self->{'snmp'}->close;

    return(0);
}


# Пиздец объекту
# Если у него открыта SNMP-сессия, ее следовало бы закрыть

sub DESTROY {
    my ($self) = @_;

    if (defined($self->{'snmp'})) {
        $self->close();
    }
}

1;
