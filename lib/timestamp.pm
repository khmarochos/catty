#
#   $Id: timestamp.pm,v 1.1 2003/04/08 18:24:52 melnik Exp $
#
#   timestamp.pm, Yet another stupid library
#   Copyright (C) 2001-2003  V.Melnik <melnik@raccoon.kiev.ua>
#
#   This library is free software; you can redistribute it and/or
#   modify it under the terms of the GNU Lesser General Public
#   License as published by the Free Software Foundation; either
#   version 2.1 of the License, or (at your option) any later version.
#
#   This library is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
#   Lesser General Public License for more details.
#
#   You should have received a copy of the GNU Lesser General Public
#   License along with this library; if not, write to the Free Software
#   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#

package timestamp;

use strict;

use Exporter;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);

use POSIX qw(strftime);

$VERSION            = '0.01';
@ISA                = qw(Exporter);
@EXPORT             = qw(timestamp2unixtime unixtime2timestamp);

sub timestamp2unixtime {
    my ($timestamp) = @_;
    if ($timestamp =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$/) {
        return(strftime("%s", ($6, $5, $4, $3, $2 - 1, $1 - 1900, -1, -1, -1)));
    } else {
        return(undef);
    }
}

sub unixtime2timestamp {
    my ($unixtime) = @_;
    return(strftime("%Y-%m-%d %H:%M:%S", localtime($unixtime)));
}

1;
