#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin";
use Market::MarketData;
use Market::Indicators::ATR;

my $market = Market::MarketData->new;
my $ruta = "$FindBin::Bin/data/2026_03.csv";
open(my $fh, "<", $ruta) or die $!;
my $primera = 1;
while (my $linea = <$fh>) {
    chomp $linea;
    if ($primera) { $primera = 0; next; }
    my ($t,$o,$h,$l,$c,$v) = split(/,/, $linea);
    $market->add_candle({ time=>$t, open=>$o+0, high=>$h+0, low=>$l+0, close=>$c+0, volume=>$v+0 });
}
close($fh);

# ATR(14) sobre 1m
$market->set_timeframe('1m');
my $atr = Market::Indicators::ATR->new(14);
$atr->update_last($market) while scalar(@{$atr->get_values}) < $market->size;

my $vals = $atr->get_values;
my $undef_count = grep { !defined } @$vals;

printf "Total valores ATR : %d\n", scalar(@$vals);
printf "Valores undef (warm-up): %d\n", $undef_count;
printf "ATR[13] (primero) : %.10f\n", $vals->[13];
printf "ATR[14]           : %.10f\n", $vals->[14];
printf "ATR[100]          : %.10f\n", $vals->[100];
printf "ATR[last=%d]    : %.10f\n", $#$vals, $vals->[-1];
