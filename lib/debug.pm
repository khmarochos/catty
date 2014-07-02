#
#   $Id: debug.pm,v 1.8 2003/04/17 10:22:37 melnik Exp $
# 
#   debug.pm, Yet another high-level logging library (I wrote it just
#   for myself only, so don't ask anything about it).
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

package debug;

use strict;

use Exporter;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);

my @debug_levels    = qw(
                        DEBUG_QUIET
                        DEBUG_ERROR
                        DEBUG_WARNING
                        DEBUG_INFO
                        DEBUG_DEBUG
);

my @debug_all       = qw(); push(@debug_all,
                        @debug_levels
);

$VERSION            = '0.43';
@ISA                = qw(Exporter);
@EXPORT             = qw();
@EXPORT_OK          = @debug_all;
%EXPORT_TAGS        = (
                        debug_levels => [@debug_levels]
);

sub DEBUG_QUIET()   { 0 };
sub DEBUG_ERROR()   { 1 };
sub DEBUG_WARNING() { 2 };
sub DEBUG_INFO()    { 3 };
sub DEBUG_DEBUG()   { 4 };

use Unix::Syslog qw(:subs :macros);
use POSIX qw(strftime);

sub new {
    my($class, %argv) = @_;
    my $self = {
        debug_level_logfile => undef,
        debug_level_stdout  => undef,
        debug_level_stderr  => undef,
        logfile             => undef,
        logfile_fh          => undef,
        error               => undef
    };
    bless($self, $class);
    foreach (keys(%argv)) {
        if (/^-?debug_level_logfile$/i) {
            $self->{'debug_level_logfile'}  = $argv{$_};
        } elsif (/^-?debug_level_stdout$/i) {
            $self->{'debug_level_stdout'}   = $argv{$_};
        } elsif (/^-?debug_level_stderr$/i) {
            $self->{'debug_level_stderr'}   = $argv{$_};
        } elsif (/^-?logfile$/i) {
            $self->{'logfile'}              = $argv{$_};
        } else {
            return(undef, "Unknown parameter $_");
        }
    }

    return($self);
}

sub reopen {
    my($self) = @_;

    if ($self->{'logfile'}) {
        unless (open(logfile_fh, ">>$self->{'logfile'}")) {
            $self->{'error'} = "Can't open(): $!";
            return(undef);
        }
        $self->{'logfile_fh'} = \*logfile_fh;
        my $old_stdout = select(logfile_fh); $| = 1; select($old_stdout);
    }
    return(0);
}

sub write {
    my($self, $debug_level, @message) = @_;

    my $now         = strftime("%Y-%m-%d %H:%M:%S", localtime);
    my @caller_arr  = caller;

    my $logfile_fh = $self->{'logfile_fh'};

    unless (@message) {
        $self->{'error'} = "Supplied message is empty";
        return(undef);
    }

    my $priority;
    CHOOSE_DL: {
        if ($debug_level == DEBUG_ERROR) {
            unshift(@message, "[ERR]");
            push(
                @message,
                "($caller_arr[1]:$caller_arr[0]:$caller_arr[2])"
            );
            last CHOOSE_DL;
        } elsif ($debug_level == DEBUG_WARNING) {
            unshift(@message, "[WRN]");
            push(
                @message,
                "($caller_arr[1]:$caller_arr[0]:$caller_arr[2])"
            );
            last CHOOSE_DL;
        } elsif ($debug_level == DEBUG_INFO) {
            unshift(@message, "[INF]");
            last CHOOSE_DL;
        } elsif ($debug_level == DEBUG_DEBUG) {
            unshift(@message, "[DBG]");
            last CHOOSE_DL;
        } else {
            unshift(@message, "[***]");
            push(
                @message,
                "($caller_arr[1]:$caller_arr[0]:$caller_arr[2])"
            );
            last CHOOSE_DL;
        }
    }

    if ($self->{'debug_level_logfile'} >= $debug_level) {
        print($logfile_fh "$now @message\n") if ($self->{'logfile_fh'});
    }
    if ($self->{'debug_level_stderr'} >= $debug_level) {
        print(STDERR "$now @message\n");
    } elsif ($self->{'debug_level_stdout'} >= $debug_level) {
        print(STDOUT "$now @message\n");
    }

    return;
}

sub close {
    my $self = shift;
    if (defined($self->{'logfile_fh'})) {
        unless (close($self->{'logfile_fh'})) {
            $self->{'logfile_fh'} = undef;
            $self->{'error'} = "Can't close(): $!";
            return(undef);
        }
    }
    $self->{'logfile_fh'} = undef;
    return(0);
}

sub DESTROY {
    my $self = shift;

    $self->close();
}

1;
