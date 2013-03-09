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

=head1 DEPENDENCIES

Finance::PaycheckRecords requires {{$t->dependency_link('HTML::TableExtract')}}.

=cut

use Exporter 5.57 'import';     # exported import method
our @EXPORT = qw(parse_paystub paystub_to_QIF);

our %parse_method = qw(
  file   parse_file
  string parse
);

our $current = 'Current';

#=====================================================================

=sub parse_paystub

  $paystub = parse_paystub(file => $filename_or_filehandle);
  $paystub = parse_paystub(string => $html);

This parses an HTML printer-friendly paystub and extracts the data
from it.  C<$paystub> is a hashref with the following keys:

=over

=item C<check_number>

The check number, if available.  May be omitted for direct deposits.

=item C<company>

The name and address of the company as it appears on the paystub.

=item C<date>

The date of the check, in whatever format it was displayed on the
paystub.

=item C<pay_period>

The pay period as it appears on the paystub.  Usually two dates
separated by a hyphen and whitespace.

=item C<payee>

The name and address of the employee as it appears on the paystub.

=item C<split>

A hashref keyed by section name (e.g. C<PAY> or C<TAXES WITHHELD>).
Each value is another hashref with an entry for each row of the table,
keyed by the first column.  That value is a hashref keyed by column name.

An example should make this clearer.  A paycheck that looks like this:

  PAY    Hours Rate  Current    YTD
  Salary             1766.65 1766.65

  TAXES WITHHELD     Current    YTD
  Federal Income Tax  333.33  333.33
  Social Security     222.22  222.22
  Medicare             99.99   99.99

  SUMMARY     Current     YTD
  Total Pay   1766.65  1766.65
  Deductions     0.00     0.00
  Taxes        655.54   655.54

Would produce this hashref:

  {
    'PAY' => {
      Salary => { Current => '1766.65', Hours => '', Rate => '',
                  YTD     => '1766.65' },
    },
    'TAXES WITHHELD' => {
      'Federal Income Tax' => { Current => '333.33', YTD => '333.33' },
      'Medicare'           => { Current =>  '99.99', YTD =>  '99.99' },
      'Social Security'    => { Current => '222.22', YTD => '222.22' },
    },
    'SUMMARY' => {
      'Deductions' => { Current =>    '0.00', YTD =>    '0.00' },
      'Taxes'      => { Current =>  '655.54', YTD =>  '655.54' },
      'Total Pay'  => { Current => '1766.65', YTD => '1766.65' },
    },
  }

=item C<totals>

A hashref containing the totals from the bottom of the check, keyed by
field name (e.g. C<'Net This Check'>).  Dollar signs, commas, and
whitespace are removed from the values.

=back

=cut

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

=sub paystub_to_QIF

  $qif_entry = paystub_to_QIF($paystub, \%config);

This function takes a C<$paystub> as returned from C<parse_paystub>
and returns a QIF record with data from the paystub.  It returns only
a single record; you'll need to add a header (e.g. C<"!Type:Bank\n">)
to form a valid QIF file.

The C<%config> hashref may contain the following keys:

=over

=item C<category>

The QIF category to use for the deposit (default C<Income>).

=item C<expenses>

A hashref in the same format as C<income>, but values are subtracted
from your income instead of added to it.

=item C<income>

A hashref that describes which entries in C<$paystub->{split}>
describe income and what category to use for each row in that section.
The key is the section name, and the value is a hashref keyed by the
first column.  That value is an arrayref: S<C<[ $category, $memo ]>>.
The C<$memo> may be omitted.  It croaks if the section contains a row
that is not described here.  However, it is ok to have an entry that
describes a row not found in the current paystub.

=item C<memo>

The QIF memo for this transaction
(default C<< "Paycheck for $paystub->{pay_period}" >>).

=item C<net_deposit>

The name of the key in C<< $paystub->{totals} >> that contains the net
deposit amount (default C<Net This Check>).

=back

=cut

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

  my $paystub = parse_paystub(file => $filename);

  print "!Type:Bank\n", paystub_to_QIF($paystub, {
    category => 'Assets:MyBank',
    memo     => $memo,
    income => {
      PAY => {
        Salary => [ 'Income:Salary' ],
      },
    },
    expenses => {
      'TAXES WITHHELD' => {
        'Federal Income Tax' => [ 'Expenses:Tax:Fed', 'Federal income tax' ],
        'Medicare'        => [ 'Expenses:Tax:Medicare', 'Medicare tax' ],
        'Social Security' => [ 'Expenses:Tax:Soc Sec', 'Social Security tax' ],
      },
    },
  });

=head1 DESCRIPTION

Finance::PaycheckRecords can parse paystubs from PaycheckRecords.com,
so you can extract the information from them.  It also includes a
function to generate a Quicken Interchange Format (QIF) record from a
paystub.


=head1 BUGS AND LIMITATIONS

I don't know how consistent the layout of paystubs for different
companies are.  If yours doesn't parse properly, please report a bug
and attach a copy of one of your paystubs (after changing the numbers
and/or addresses if you don't want to tell everyone your salary).


=head1 SEE ALSO

L<Finance::PaycheckRecords::Fetcher> can be used to automatically
download paystubs from PaycheckRecords.com.

The Quicken Interchange Format (QIF):
L<http://web.archive.org/web/20100222214101/http://web.intuit.com/support/quicken/docs/d_qif.html>
