#---------------------------------------------------------------------
package Finance::PaycheckRecords;
#
# Copyright 2013 Christopher J. Madsen
#
# Author: Christopher J. Madsen <perl@cjmweb.net>
# Created: 2 Feb 2013
#
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See either the
# GNU General Public License or the Artistic License for more details.
#
# ABSTRACT: Parse data from PaycheckRecords.com
#---------------------------------------------------------------------

use 5.010;
use strict;
use warnings;

our $VERSION = '0.01';
# This file is part of {{$dist}} {{$dist_version}} ({{$date}})

use Carp qw(croak);
use HTML::TableExtract 2.10;
use List::Util qw(sum);

use Exporter 5.57 'import';     # exported import method
our @EXPORT = qw(parse_paystub paystub_to_QIF);

our %parse_method = qw(
  file   parse_file
  string parse
);

our $current = 'Current';

#=====================================================================
sub parse_paystub
{
  my ($input_type, $input) = @_;

  my $parse_method = $parse_method{$input_type}
      or croak("Don't know how to parse '$input_type'");

  my $te = HTML::TableExtract->new;
  $te->$parse_method($input);

  my %paystub;

  foreach my $ts ($te->tables) {
    my @coords = $ts->coords;
    my @rows   = $ts->rows;

    no warnings 'uninitialized';
    if ($coords[0] == 2) {
      $paystub{pay_period} = $1
          if $rows[0][0] =~ /^\s*Pay stub for period:\s*(\S.+\S)\s*\z/s;
    } elsif ($coords[0] == 4 and $coords[1] == 0) {
      $paystub{company} = $rows[0][0];
      $paystub{payee}   = $rows[2][0];
      $paystub{check_number}    = $1
          if $rows[0][2] =~ /\bCheck\s*#\s*(\d+)/;
      $paystub{date}    = $1
          if $rows[0][2] =~ /\bDate:\s*(\S.+\S)/;
      for (@paystub{qw(company payee)}) {
        next unless defined;
        s/^[\s\xA0]+//;
        s/[\s\xA0]+\z//;
        s/\n[ \t]+/\n/g;
        s/\n{2,}/\n/g;
      }
    } elsif ($coords[0] == 3) {
      if ($rows[0][-1] =~ /^\s*YTD\s*\z/ ) {
        my $headings = shift @rows;
        my %table;
        $paystub{split}{ shift @$headings } = \%table;
        for my $row (@rows) {
          for (@$row) {
            next unless defined;
            s/^[\s\xA0]+//;
            s/[\s\xA0]+\z//;
          }
          my $category = shift @$row;
          @{ $table{$category} }{@$headings} = @$row;
        }
      } # end if YTD
      elsif ($rows[0][0] =~ /^\s*Net\s+This\s+Check:/) {
        for my $row (@rows) {
          for (@$row) {
            next unless defined;
            s/^[\s\xA0]+//;
            s/[\s\xA0]+\z//;
          }
          $row->[0] =~ s/:\z//;
          $row->[1] =~ s/[\$,]//g;

          $paystub{totals}{$row->[0]} = $row->[1];
        }
      } # end if Net This Check
    }
  } # end for each $ts in tables

  \%paystub;
} # end parse_paystub

#---------------------------------------------------------------------

sub paystub_to_QIF
{
  my ($paystub, $config) = @_;

  my $net_deposit = $paystub->{totals}{ $config->{net_deposit}
                                         // 'Net This Check'};
  my @splits;

  _add_splits(\@splits, $paystub, $config->{income},   '');
  _add_splits(\@splits, $paystub, $config->{expenses}, '-');

  my $sum = sprintf "%.2f", sum( map { $_->[0] } @splits);
  croak("Sum of splits $sum != Net $net_deposit") unless $sum eq $net_deposit;

  my $qif = "D$paystub->{date}\n";

  $qif .= "N$paystub->{check_number}\n" if length $paystub->{check_number};

  my $company = $paystub->{company};
  $company =~ s/\n/\nA/g;       # Subsequent lines are address
  $qif .= "P$company\n";

  my $memo = $config->{memo} // "Paycheck for $paystub->{pay_period}";
  $qif .= "M$memo\n" if length $memo;

  $qif .= sprintf "T%s\nL%s\n", $net_deposit, $config->{category} // 'Income';

  for my $split (@splits) {
    $qif .= "S$split->[1]\n";
    $qif .= "E$split->[2]\n" if length $split->[2];
    $qif .= "\$$split->[0]\n";
  }

  $qif . "^\n";
} # end paystub_to_QIF

#---------------------------------------------------------------------
sub _add_splits
{
  my ($splits, $paystub, $config, $sign) = @_;

  while (my ($section, $fields) = each %$config) {
    while (my ($field, $values) = each %{ $paystub->{split}{$section} }) {

      next unless ($values->{$current} // 0) != 0;

      croak("Don't know what to do with $section: '$field'")
          unless $fields->{$field};

      push @$splits, [ $sign . $values->{$current}, @{ $fields->{$field} } ];
    }
  }
} # end _add_splits

#=====================================================================
# Package Return Value:

1;

__END__

=head1 SYNOPSIS

  use Finance::PaycheckRecords;
