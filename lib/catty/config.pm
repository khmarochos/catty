#
#   $Id: config.pm,v 1.9 2003/04/20 00:05:13 melnik Exp $
#

package catty::config;

use strict;

use Exporter;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);

use FindBin qw($Bin);

my @CATTY_main      = qw(
                        &CATTY_version
);
my @CATTY_ALL       = qw(); push(@CATTY_ALL,
                        @CATTY_main
);

@ISA            = qw(Exporter);
@EXPORT         = qw();
@EXPORT_OK      = @CATTY_ALL;
%EXPORT_TAGS    = (
                    CATTY_main      => [@CATTY_main]
);

#- :CATTY_main
sub CATTY_version()             { '3.0.0' };

1;
