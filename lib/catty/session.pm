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


# �����-���� ������������� �������, ���������� ��� �������: ��������� ��
# ������ (� ������ ������ - undef) � ��������� �� ������ (� ������ ����������
# ������ - undef)

sub new {
    my($class, %argv) = @_;

    # ��������� ������ ������

    my $self = {
        session         => undef,   # ������������� ������
        user            => undef,   # ������ ������ catty::user
        nas             => undef,   # ������ ������ catty::nas
        nasport         => undef,   # ����� ����� NAS, �������� �������
        nasmagic        => undef,   # magic-����� ������ �� NAS
        csid            => undef,   # ������ ���
        time_start      => undef,   # ����� ������ ������
        time_stop       => undef,   # ����� ������� ������
        time_used       => undef,   # ������� ������� �� �������� �� �����
        traf_input      => undef,   # ������� �������� �������
        traf_output     => undef,   # ������� ������������ �������
        traf_input_now  => undef,   # ������� �������� ������� "�������"
        traf_output_now => undef,   # ������� ������������ ������� "�������"
        traf_input_was  => undef,   # ���������� �������� $traf_input_now
        traf_output_was => undef,   # ���������� �������� $traf_output_now
        advertized      => undef,   # ����� � ��������� ��� ������������� �������?
        last_update     => undef,   # ����� � ��������� ��� ����������� ����?
        cost            => undef,   # ��������� ���������� ������
        kill_it         => undef,   # ���� ����� ������� - ������ ����� ������
        dbh_c           => undef,   # ������ ������ DBI::db ��� catty
        dbh_r           => undef,   # ������ ������ DBI::db ��� radius
        justfind        => undef,   # ������, ��������� ����!
        time_now        => undef,   # ����� ������ ���� ��������
        error           => undef,   # ��������� �� ������
        # ��� ��� ����� ������ �� ������� ������ DBI::st, ��������� ����� ����
        sth_find_session            => undef,
        sth_create_session          => undef,
        sth_get_session_acct        => undef,
        sth_get_cost                => undef,
        sth_write_acctdata          => undef
    };

    bless($self, $class);

    # ��������� �������� ����������
    #       -session    => ������������� ������
    #       -user       => ������ ������ catty::user
    #       -nas        => ������ ������ catty::nas
    #       -nasport    => ����� ����� NAS, �������� �������
    #       -csid       => ������ ���
    #       -dbh_c      => ������ ������ DBI::db ��� catty
    #       -dbh_r      => ������ ������ DBI::db ��� radius
    #       -justfind   => ���� TRUE, ����� ������ �������� ������������ ������
    #                      � �������, �� ��������� ����� ���������

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


    # ���������� ������� ��� DBI::st

    # ��� ��� ����������� ������ � ��������� �������� ��������� �� �� ������

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

    # ��� ��� �������� ����� ������ � ������� sessions

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

    # ��������� ������ � ������ �� ������� FreeRADIUS

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

    # ��������� ������ � ���������

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

    # ��� ���� - ��� ������ �������������� ���������� � ������� sessions

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


    # ��������, �ӣ �� ��������� � ���� �������, ������������� �� ������������
    # ��� �� ���� NAS � ������ ������� ţ magic-�����

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


    # ������� ����� ������ � ������� ������

    unless (defined($self->db_new)) {
        return(
            undef,
            "Can't catty::session->db_new(): " . $self->{'error'}
        );
    }

    return($self, undef);
}


# �������� ����� ������ � ������� ������� ��� ���������� ������ � ������
# (� ������, ���� ������ ���� ��������� ��������)

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


# ����� RADIUS �� ������� ������� ������: ������� ������ � ���������
# ������ � ���������� ��������� �� ����� �������

sub query_radius {
    my ($self, $time_now) = @_;

    # ��������� ������� ���������� � �������� ������

    unless (
        defined($self->{'sth_get_session_acct'}->execute($self->{'session'}))
    ) {
        $self->{'error'} =
            "Can't DBI::db->execute(): " . $self->{'dbh_r'}->errstr;
        return(undef);
    }

    # � ����������� �� ����, ����� �� �������� NAS �������� �������������
    # ���������� � ��������� ������� �� RADIUS, �������� ��� �� ��������
    # ������ �� ���� �� RADIUS (���� �� ����� - �� �������� � ��������
    # �� ����� �� SNMP).

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

    # ���� ������ �� ���������, ������������ � �����

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


# ��������� �������� �������, ������������ ������������� ��-���� �����
# ������ � ������ ����-��������.
# �� ����� ������� $time_now (������� �����) � $time_was (����� �����������
# ������� ������������).
# ���������� ������� �������� ��� undef, � ������ ������
# ��������� ���������� �������� � $self->{'time_used'}.

sub count_time {
    my ($self, $time_now, $time_was) = @_;

    # ���� ������ �� RADIUS ���������� �������� - ��������

    if ($time_now ne $self->{'last_update'}) {
        $self->{'error'} =
            "I didn't received any information from RADIUS, " .
            "last updated " . $self->{'last_update'};
        return(undef);
    }

    # ����������� ����������.
    # ���������� �������, ������������ ��-���� �� ��������� ����������
    # ������� ����� ������� X - Y, ��� X ����� ������� �������� ������
    # (��� �������� �������, ���� ������ ��� �� �����������), � Y �����
    # ������� ���������� �������� (��� ������� ������ ������, ���� ���
    # ������ �������� ��� ����� ��������� ���������� ��������).

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


# ��������� �������� ���������� �������, �������� � ���������� ��������������
# � ������� ����������� ������ (������, ���, ��������� �����)

sub count_traffic {
    my ($self, $time_now) = @_;

    # ���� ������ �� RADIUS ���������� �������� - ��������

    if ($time_now ne $self->{'last_update'}) {
        $self->{'error'} =
            "I didn't received any information from RADIUS, " .
            "last updated " . $self->{'last_update'};
        return(undef)
    }

    # ���� $self->{'nas'}->{'nsrac'} ���������� TRUE, ��� ��������, ��� NAS
    # ����� �������������� �������� ������� ���������� RADIUS � ��������
    # ������, �� ����� ����� ������ ��������������� ������, � �� �������
    # ��������� ���������� NAS � SNMP-�����������
    # ������� �������� �������� �� ��, ��� �� �� ������ ������� NAS � ���
    # ������, ���� ��� ������ ��� ���� �������, ����� �������� �� �������
    # ������ � �������� � ������ ������, ������� ��� ������ ������ ���� ���
    # ���������!

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

    # �������� ������ � ���������� ���������; �� ������ ������ ����� �� � �����
    # ����� ��������� �����������.

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

    # ����, �� ������ �����!!! (2004-02-26)

    return(0);
}


# ��������� �������� ��������� ������������ ������������� ����� � �����������
# �� ��������� ����� ������������, �������, ����������� ��� ��-���� � ��������,
# ������� �� ������ � ������� � ������� ���������� ���������������� �������.
# ���������, ����� �� ��������� ������������ (���� � ������ ������ ���
# �������� ����� �� ��������������� ���������� ������� � ����).
# ���������� ��������� ���������� � $self->{'cost'}.
# ���������� 0 ��� undef � ������ ������.
# �� ����� ������� $time_now.

sub count_cost {
    my ($self, $time_now) = @_;

    # ���� ������ �� RADIUS ���������� �������� - ��������

    if ($time_now ne $self->{'last_update'}) {
        $self->{'error'} =
            "I didn't received any information from RADIUS, " .
            "last updated " . $self->{'last_update'};
        return(undef);
    }

    # ��������� ������ ����������� ������� ��������� �����.

    unless (defined($self->{'sth_get_cost'}->execute(
        $self->{'user'}->{'upack'},
    ))) {
        $self->{'error'} =
            "Can't DBI::st->execute(): " . $self->{'dbh_c'}->errstr;
        return(undef);
    }

    # ������ ����, ����� �������� ��� ������ �� ���� �������� ������ � �����
    # ����������, ���������� �������.

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

        # ����� �� ��������� �� ���������� �������� � $db_cmoment, �������
        # �������� ����� ��������� ���� ������ ��� ������������ �������
        # ��������� ������, ������� ��� ����������.
        
        $db_cmoment = undef;
    }

    unless (defined($self->{'sth_get_cost'}->finish)) {
        $self->{'error'} =
            "Can't DBI::st->finish(): " . $self->{'dbh_c'}->errstr;
        return(undef);
    }

    # ���� �����-�� �� ���� �������� ���������� undef, ��� ������, ��� �
    # ������� ����������� �� ��� � ������� � ��� � �������� �������� �����
    # � ��� ����������� ���� ��������

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

    # ���� ������������ ����������� �� "call-back", $db_c[...] ��������
    # �������� �� $db_c[...]cb, ���� �� ��� ���� �ݣ � "���������", ��
    # �������� �������� �� $db_c[...]cbd

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

    # ���� �����-�� �� ���� �������� ��������������� ����� ����������
    # ������������� ��������, ��� ��������, ��� � ��������� ����� ������
    # �������� � ������������ ������� ��������� �����

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


# ��������� �������� ����� cmoment �� ������������ ������� ���� � �������.
# �������� �� ����� ��������� $moment (����� costs.cmoment, ����������� ��
# ������ ������), �������� $dow (���� ������) � �������� $hod (��� �����).
# ���������� 1 ��� 0. ���, �������, undef � ������ �����.

sub check_moment {
    my ($self, $moment, $hod, $dow) = @_;

    my $dow_b;
    my $dow_e;
    my $hod_b;
    my $hod_e;

    # ����� ������� ����������� ������� �Σ�, � �� �������.

    $dow = 7 if ($dow == 0);

    # ����������� ������ �� ������������ �������.
    
    if ($moment =~ /^([a-z]{1,2})(-([a-z]{1,2}))?([0-9]{1,2})(-([0-9]{1,2}))?$/i) {

        # ��������� ��������� ���������� ���� (1-7) �� ������ �����
        # ���������� ���������� ���� (Al, Wk, Wd, ...).
    
        ($dow_b, $dow_e) = $self->convert_days($1);

        if (defined($dow_e) && defined($3)) {
        
            # ���� ������� ������� ��� �������� ������ ������, ��� ��������,
            # ��� � ������ ����� ���������� ���������� ��� ����� �����
            # ���������� � ��� �������� ��������� ������ "Al", "Wk" ��� "Wd".
            # ���� ��� ���� �����-�� ���� ������ ������ ����� ����������
            # ���������� ����, ��� ��������, ��� � ������-�� ����ϣ�� ������
            # ����������� ����.

            $self->{'error'} = "Lame cmoment: $moment";
            return(undef);

        } elsif (! defined($dow_e)) {

            # ���� ������� ������� ������ ���� ��������, ��� ��������, ��� ���
            # ������� ���������� ������ �������� ���������� ����������, ��� �
            # ������ �������� ������� ��ͣ��� �� ����� ���������� ����������
            # �� ����.

            if (defined($3)) {

                # ���� ��� ���� � ����� ��������� ���������� ������������
                # ������ �������� ��������, �� �������������� � ţ.

                my ($dow_e1, $dow_e2) = $self->convert_days($3);

                if (defined($dow_e2)) {

                    # ���� ������ �������� ������� ������-�� ��� ��������,
                    # ��� �� ����� �����-�� �����, ��������� ������ ����
                    # "Fr-Al" �������� ���-�� ������ �����������.
                
                    $self->{'error'} = "Lame cmoment: $moment";
                    return(undef);

                }

                $dow_e = $dow_e1;

            } else {

                # � ��������� �� ������ ����� ���������� ����� ��� ������.

                $dow_e = $dow_b;

            }
        }

        # ���� �� �� ��� � �� �������� �������� ���������� ���� ������, ���
        # �������� ������ ��, ��� ��������� ����� ������ � ��� ������� ���� ��
        # ���������� ���������� ���������� "��-����-����" � ����� ����������
        # ����������.
        
        unless (defined($dow_b) && defined($dow_e)) {
            $self->{'error'} =
                "Can't catty::session::convert_days(): " . $self->{'error'};
            return(undef);
        }

        # ���������� � ��������� ���������� ����� � ��� �� �������� ��������
        # ������ ����������.

        $hod_b = $4;

        # ���� ��� ����� ����� ����������, ��������� ��� �� ������, ���� ��
        # ��� ���������� �� �������, ����� ���������� ����� ��� ������ �
        # ������������������.

        if (defined($6)) {
            $hod_e = $6;
        } else {
            $hod_e = $hod_b + 1;
        }

        # ��������� ���������� ����� ���������� �����.

        if ($hod_b == $hod_e) {

            # ��� �� ����� ���� �����, ��������� �������� ���������� ��������
            # ���������� "0-24", � �� "0-0" ��� "13-13".
        
            $self->{'error'} = "Lame cmoment: $moment";
            return(undef);

        } elsif (
            ($hod_b < 0)    ||
            ($hod_b > 23)   ||
            ($hod_e < 1)    ||
            ($hod_e > 24) 
        ) {

            # ������ �� ����� ���� ������ 0 ��� ������ 23, � ����� �� �����
            # ���� ������ 1 � ������ 24.

            $self->{'error'} = "Lame cmoment: $moment";
            return(undef);
        
        }
        
        # ���� �� ��� � �� �������� �������� ���������� �����, ������.
        
        if (! (defined($hod_b) && defined($hod_e))) {
            $self->{'error'} = "Lame cmoment: $moment";
            return(undef);
        }
        
    } else {

        # ���� ������ �� ������������� �������, ����� ���, ��� ţ ��������,
        # ������� ţ ���� � �������.
    
        $self->{'error'} = "Lame cmoment: $moment";
        return(undef);

    }

    # ����������, �������� ��������� �������� ������� � ����������.

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


# ��������� �������������� ���� ������ �� ���� � �����.

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


# ��������� ������ ������� ����������
# $cost ����� ��� ��� ����, ����� �������������� � ���, ��� �� ������ ��
# ������ �������� ���������� � ������, �� � ��������� ������������� �����
# � ���� ���������. ���� �� $cost ��� ��� ������ �� �����, ��� �������� ��,
# ��� ������ ������ ����� �������, � ��� ���������� � ��� ������ ��
# ���������������� ����� (� catty::session->close()) � ��� ����������
# ��������� (� catty::session->DESTROY()).

sub write_acctdata {
    my ($self, $cost) = @_;

    unless (defined($self->{'sth_write_acctdata'}->execute(
        $self->{'time_start'},
        $self->{'time_stop'},
        # ���� ��� undef'�, ������ 0, ����� SQL ������ ��� �� ���
        (defined($self->{'traf_input'})  ? $self->{'traf_input'}  : 0),
        (defined($self->{'traf_output'}) ? $self->{'traf_output'} : 0),
        (defined($cost)                  ? $self->{'cost'}        : 0),
        # � ��� ��� ��� undef'�� ���� �� ������...
        $self->{'session'}
    ))) {
        $self->{'error'} =
            "Can't DBI::st->execute(): " . $self->{'dbh_c'}->errstr;
        return(undef);
    }

    return(0);
}


# ���������� ������ (����� ���� ��������������)

sub close {
    my ($self) = @_;

    # ���� ������ ����������, ���������� �� ������� �������� � ����������
    # ������ � ���� ������

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


# ������ �������

sub DESTROY {
    my ($self) = @_;

    if (defined($self->{'session'})) {
        $self->close();
    }
}


1;
