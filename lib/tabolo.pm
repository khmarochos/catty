#
#   $Id: tabolo.pm,v 1.2 2003/04/13 04:43:03 melnik Exp $
#
#   tabolo.pm, A library for ascii-tables printing
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

package tabolo;

use strict;

use Exporter;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);

use POSIX qw(strftime);

$VERSION            = '0.01';
@ISA                = qw(Exporter);
@EXPORT             = qw(tabolo);

sub tabolo {
    my ($ref_table) = @_;

    my $row;
    my $col;

    my @col_lengths;
    my $col_size_max;
    my $cols;

    my @out_array;
    my $out_string;

    $row = 0;
    foreach my $ref_row (@{$ref_table}) {
        $col = 0;
        foreach my $value (@{$ref_row}) {
            if (length($value) > $col_lengths[$col]) {
                $col_lengths[$col] = length($value);
            }
            $col++;
        }
        if ($col > $col_size_max) {
            $col_size_max = $col;
        }
        $row++;
    }

    $row = 0;
    push(@out_array, draw_line(\@col_lengths));
    foreach my $ref_row (@{$ref_table}) {
        if ($row == 1) {
            push(@out_array, draw_line(\@col_lengths));
            $cols = $col;
        }
        $col = 0;
        $out_string = "";
        foreach my $value (
            @{$ref_row}, split(//, "-"x($col_size_max - scalar(@{$ref_row})))
        ) {
            $out_string .= sprintf("| %" . $col_lengths[$col] . "s ", $value);
            $col++;
        }
        $out_string .= "|\n";
        $row++;
        push(@out_array, $out_string);
    }
    push(@out_array, draw_line(\@col_lengths));

    return(@out_array);
}

sub draw_line {
    my ($ref_col_lengths) = @_;

    my $out_string;

    foreach my $col_length (@{$ref_col_lengths}) {
        $out_string .= "+-" . "-"x$col_length . "-";
    }
    $out_string .= "+\n";

    return($out_string);
}

1;
