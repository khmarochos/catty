#
#   $Id: cgi.pm,v 1.3 2003/04/11 17:51:31 melnik Exp $
#

package catty::cgi;

use strict;

use Exporter;

use FindBin qw($Bin);

use lib "$Bin/../lib";

use CGI;
use Text::Template;
use POSIX qw(strftime);

use vars qw(@ISA @EXPORT);

@ISA            = qw(Exporter);
@EXPORT         = qw();

sub new {
    my ($class, %argv) = @_;

    my $self = {
        error           => undef,
        cgi             => undef,
        warnings        => undef,
        comments        => undef
    };

    bless($self, $class);


    # Процедура парсинга параметров

    foreach (keys(%argv)) {
        if (/^-?templates/i) {
            $self->{'templates'} = $argv{$_};
        } else {
            return(undef, "Unknown parameter $_");
        }
    }


    $self->{'cgi'} = CGI->new;

    return($self, undef);
}

sub draw_error {
    my ($self, $error) = @_;

    my @caller_arr = caller;

    print($self->{'cgi'}->header(
        -expires    => '-1m',
        -status     => '500 Internal Script Error'
    ));
    
    my $template = Text::Template->new(
        TYPE        => "FILE",
        SOURCE      => "$Bin/../lib/catty/html-template/error.html",
        DELIMITERS  => ["<!--", "--!>"]
    );
    my %template_vars = (
        error       => \$error,
        caller_arr  => \@caller_arr
    );
    if (defined(my $text = $template->fill_in(HASH => \%template_vars))) {
        print($text);
    } else {
        $self->{'error'} =
            "Ошибка при выполнении Text::Template->fill_in(): " .
            $Text::Template::ERROR;
        return(undef)
    }
    return(0)
}

sub html_entities {
    my ($self, $scalar) = @_;

    $scalar =~ s/</&lt;/g;
    $scalar =~ s/>/&gt;/g;
    $scalar =~ s/"/&quot;/g;

    $scalar =~ s/\r?\n\r?/<br>\n/g;

    return($scalar);
}

1;
