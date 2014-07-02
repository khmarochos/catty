#
#   $Id: user.pm,v 1.4 2003/04/11 21:37:45 melnik Exp $
#

package catty::user;

use strict;

use timestamp;

use Exporter;
use vars qw($VERSION @ISA @EXPORT);

$VERSION            = '0.01';
@ISA                = qw(Exporter);
@EXPORT             = qw();


# �����-���� ������������� �������, ���������� ��� �������: ��������� ��
# ������ (� ������ ������ - undef) � ��������� �� ������ (� ������ ����������
# ������ - undef)

sub new {
    my($class, %argv) = @_;

    # ��������� ������ ������

    my $self = {
        uid             => undef,   # ������������� ������ � ������������
        ulogin          => undef,   # �����-��� ������������
        uname           => undef,   # ������ ��� ������������
        upack           => undef,   # �������� ����� ������������
        udbtr           => undef,   # ���� �� �������, ����� ��� �� �����, ���
        udbtrd          => undef,   # ���� � ����� ��������� �������
        ucreate         => undef,   # ����� �������� ��������
        uexpire         => undef,   # ����� ��������� ��������
        unotifyemail    => undef,   # �������������� ����� ��� ��������������
        unotified       => undef,   # ���� � ����� ���������� ��������������
        unotifiedc      => undef,   # ���������� ��������� ��������������
        uslimit         => undef,   # ����������� � ������� ������������ ������
        ukname          => undef,   # ������������ ��������� �����
        uklogins        => undef,   # �������� ������������� �����������
        ukthreshold     => undef,   # ������� ��������� ����� ��� ������
        ukmute          => undef,   # ��� ����� ��������� �� ��������������
        ukcb            => undef,   # ��������� ������ callback
        uktid           => undef,   # ��� �������� ����� ������������
        ubalance        => undef,   # ����� ������
        ubalance_t      => undef,   # ���� � ����� ������������� �������
        ubalance_c      => undef,   # ����������� ������
        ubalance_n      => undef,   # ����������� ������
        upsum_sum       => undef,   # ����� ���� ��������
        uscost_sum      => undef,   # ����� ���� ������� �� ������
        ulpexpire       => undef,   # ���� ���������� �������� ��������
        usessions       => undef,   # ������ ������
        dbh_c           => undef,   # ������ ������ DBI::db ��� catty
        dbh_r           => undef,   # ������ ������ DBI::db ��� radius
        error           => undef,   # ��������� �� ������
        # ������ �� ������� ������ DBI::st, ������� ��� �ݣ �����������
        sth_chk_p       => undef,
        sth_chk_s       => undef,
        sth_finger      => undef
    };

    bless($self, $class);

    # ��������� �������� ����������
    #       -usename    => �����-��� ������������

    foreach (keys(%argv)) {
        if (/^-?ulogin/i) {
            $self->{'ulogin'}       = $argv{$_};
        } elsif (/^-?dbh_c$/i) {
            $self->{'dbh_c'}        = $argv{$_};
        } elsif (/^-?dbh_r$/i) {
            $self->{'dbh_r'}        = $argv{$_};
        } elsif (/^-?ubalance_t$/i) {
            $self->{'ubalance_t'}   = $argv{$_};
        } else {
            return(undef, "Unknown parameter $_");
        }
    }

    
    # �������������� �� ������� ������� ��� �������� �������

    $self->{'sth_chk_p'} = $self->{'dbh_c'}->prepare(
        "SELECT " .
            "SUM(payments.psum), " .
            "MAX(payments.pexpire) " .
        "FROM " .
            "payments " .
        "WHERE " .
            "payments.puser = ? AND " .
            "payments.ppack = ? AND " .
            "(" .
                "(" .
                    "payments.ppack = 1" .
                ") OR " .
                "(" .
                    "payments.ppack = 2 AND " .
                    "payments.pcreate <= ? AND " .
                    "payments.pexpire >= ?" .
                ") OR " .
                "(" .
                    "payments.ppack = 3 AND " .
                    "payments.pcreate <= ? AND " .
                    "payments.pexpire >= ?" .
                ")" .
            ") AND " .
            "payments.ppaid != 0 AND " .
            "payments.paborted = 0 AND " .
            "payments.psum > 0 AND " .
            "(" .
                "(" .
                    "? = 0 AND " .
                    "payments.pcreate < ?" .
                ") OR" .
                "(" .
                    "? = 1 AND " .
                    "payments.pcreate >= ?" .
                ")" .
            ")"
    );

    $self->{'sth_chk_s'} = $self->{'dbh_c'}->prepare(
        "SELECT " .
            "SUM(sessions.scost) " .
        "FROM " .
            "sessions " .
        "WHERE " .
            "sessions.suser = ? AND " .
            "sessions.spack = ? AND " .
            "(" .
                "(" .
                    "sessions.spack = 1" .
                ") OR " .
                "(" .
                    "sessions.spack = 2" .
                ") OR " .
                "(" .
                    "sessions.spack = 3 AND " .
                    "sessions.stime_start >= DATE_FORMAT(?, '%Y-%m-%d 00:00:00')" .
                ")" .
            ") AND " .
            "(" .
                "(" .
                    "? = 0 AND " .
                    "sessions.stime_start < ?" .
                ") OR" .
                "(" .
                    "? = 1 AND " .
                    "sessions.stime_start >= ?" .
                ")" .
            ")"
    );

    # � ������ ��� ��������� ������ � ������ ��� ���� ����� ���������� ��...

    $self->{'sth_finger'} = $self->{'dbh_c'}->prepare(
        "SELECT " .
            "users.uid, " .
            "users.uname, " .
            "users.upack, " .
            "users.udbtr, " .
            "users.udbtrd, " .
            "users.ucreate, " .
            "users.uexpire, " .
            "users.unotifyemail, " .
            "users.unotified, " .
            "users.unotifiedc, " .
            "users.uslimit, " .
            "packages.kname, " .
            "packages.klogins, " .
            "packages.kthreshold, " .
            "packages.kmute, " .
            "packages.kcb, " .
            "ptypes.ktid " .
        "FROM " .
            "users, packages, ptypes " .
        "WHERE " .
            "users.ulogin = ? AND " .
            "users.upack = packages.kid AND " .
            "ptypes.ktid = packages.ktype"
    );

    # � ��� ����� ���������� ������ � ���, ����� � ����� ����� � ��������� ���
    # ��������� ���� ��������������, ���� �� ���������� ��� ������ ��� ����
    # ���Σ�.

    $self->{'sth_update_unotified'} = $self->{'dbh_c'}->prepare(
        "UPDATE users " .
        "SET " .
            "unotified = ?, " .
            "unotifiedc = unotifiedc + 1 " .
        "WHERE uid = ?"
    );


    # ��������, ����� �������� ����� � ����� �����

    unless (defined($self->finger)) {
        return(
            undef,
            "Can't catty::user->finger(): " . $self->{'error'}
        );
    }


    # ���� ������:)

    return($self, undef);
}


# ��������� �������� ������� ������������

sub check_balance {
    my ($self, $session_id, $time_now) = @_;

    my $psum_sum;
    my $scost_sum;


    # FIXME

    unless ($self->{'ubalance_cy'}) {
        $self->{'ubalance_cy'} = 0;
    }


    # �������� ����� ���� ��������. ���� � ��� ��� ���� ����� ���, ��
    # ��������� ������ �� �����, ������� ��������� � ���� ����������
    # ����������, ������� ������ �� ������ ������ �������� ������ �����
    # ������������. � ��������� ������ �� ��������� �����, ������������
    # ��� ����� ����� �������.

    unless (defined($self->{'sth_chk_p'}->execute(
        $self->{'uid'},
        $self->{'uktid'},
        $time_now,
        $time_now,
        $time_now,
        $time_now,
        $self->{'ubalance_cy'},
        $self->{'ubalance_t'},
        $self->{'ubalance_cy'},
        $self->{'ubalance_t'}
    ))) {
        $self->{'error'} =
            "Can't DBI::st->execute(): " . $self->{'dbh_c'}->errstr;
        return(undef);
    }

    (
        $self->{'upsum_sum'},
        $self->{'ulpexpire'}
    ) = $self->{'sth_chk_p'}->fetchrow_array;

    unless (defined($self->{'sth_chk_p'}->finish)) {
        $self->{'error'} =
            "Can't DBI::st->finish(): " . $self->{'dbh_c'}->errstr;
        return(undef);
    }


    # �������� ����� ���� ������� �� ������. ����� ��� ��, ��� � �
    # ������ � ���������, ��� ������ ������� �� ��������� �����,
    # ������������ �� ������� ������ ������ �������� ������, � ���
    # ����������� - ����� ����� �������.

    unless (defined($self->{'sth_chk_s'}->execute(
        $self->{'uid'},
        $self->{'uktid'},
        $time_now,
        $self->{'ubalance_cy'},
        $self->{'ubalance_t'},
        $self->{'ubalance_cy'},
        $self->{'ubalance_t'}
    ))) {
        $self->{'error'} =
            "Can't DBI::st->execute(): " . $self->{'dbh_c'}->errstr;
        return(undef);
    }
    
    ($self->{'uscost_sum'}) = $self->{'sth_chk_s'}->fetchrow_array;

    unless (defined($self->{'sth_chk_s'}->finish)) {
        $self->{'error'} =
            "Can't DBI::st->finish(): " . $self->{'dbh_c'}->errstr;
        return(undef);
    }


    # �������� ������� �...

    if ($self->{'ubalance_cy'}) {
        $self->{'ubalance_n'} = $self->{'upsum_sum'} - $self->{'uscost_sum'};
    } else {
        $self->{'ubalance_c'} = $self->{'upsum_sum'} - $self->{'uscost_sum'};
        $self->{'ubalance_n'} = 0;
        $self->{'ubalance_cy'} = 1;
    }
    $self->{'ubalance'} = $self->{'ubalance_c'} + $self->{'ubalance_n'};


    # ...� ������� � �������! :)

    return($self->{'ubalance'});
}


# ��������� ��������� ������ � ������������.
# ���������� 0, ������������� ���������� ������ �������.

sub finger {
    my ($self) = @_;

    unless (defined($self->{'sth_finger'}->execute($self->{'ulogin'}))) {
        $self->{'error'} =
            "Can't DBI::st->execute(): " . $self->{'dbh_c'}->errstr;
        return(undef);
    }

    (
        $self->{'uid'},
        $self->{'uname'},
        $self->{'upack'},
        $self->{'udbtr'},
        $self->{'udbtrd'},
        $self->{'ucreate'},
        $self->{'uexpire'},
        $self->{'unotifyemail'},
        $self->{'unotified'},
        $self->{'unotifiedc'},
        $self->{'uslimit'},
        $self->{'ukname'},
        $self->{'uklogins'},
        $self->{'ukthreshold'},
        $self->{'ukmute'},
        $self->{'ukcb'},
        $self->{'uktid'}
    ) = $self->{'sth_finger'}->fetchrow_array;

    unless (defined($self->{'sth_finger'}->finish)) {
        $self->{'error'} =
            "Can't DBI::st->finish(): " . $self->{'dbh_c'}->errstr;
        return(undef);
    }

    unless (
        defined($self->{'uid'}) &&
        defined($self->{'uname'}) &&
        defined($self->{'upack'}) &&
        defined($self->{'udbtr'}) &&
        defined($self->{'udbtrd'}) &&
        defined($self->{'ucreate'}) &&
        defined($self->{'uexpire'}) &&
        defined($self->{'unotified'}) &&
        defined($self->{'uslimit'}) &&
        defined($self->{'uklogins'}) &&
        defined($self->{'ukthreshold'}) &&
        defined($self->{'ukmute'}) &&
        defined($self->{'ukcb'}) &&
        defined($self->{'uktid'})
    ) {
        $self->{'error'} =
            "Can't find information about $self->{'ulogin'} (" .
                $self->{'uid'} . ":" .
                $self->{'uname'} . ":" .
                $self->{'upack'} . ":" .
                $self->{'udbtr'} . ":" .
                $self->{'udbtrd'} . ":" .
                $self->{'ucreate'} . ":" .
                $self->{'uexpire'} . ":" .
                $self->{'unotified'} . ":" .
                $self->{'uslimit'} . ":" .
                $self->{'uklogins'} . ":" .
                $self->{'ukthreshold'} . ":" .
                $self->{'ukmute'} . ":" .
                $self->{'ukcb'} . ":" .
                $self->{'uktid'} .
            ")";
        return(undef);
    }


    return(0);
    
}


# ��������� ���������� ������ � ��������� �������������� ������������, ��
# ���������� 0

sub update_unotified {

    my ($self, $time_now) = @_;

    unless (defined($self->{'sth_update_unotified'}->execute(
        $time_now,
        $self->{'uid'}
    ))) {
        $self->{'error'} =
            "Can't DBI::st->execute(): " . $self->{'dbh_c'}->errstr;
        return(undef);
    }

    return(0);

}
1;
