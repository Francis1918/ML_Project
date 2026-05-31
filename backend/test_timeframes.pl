#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin";
use Market::MarketData;

my $market = Market::MarketData->new;

# Cargar el CSV de 1m
my $ruta = "$FindBin::Bin/data/2026_03.csv";
open(my $fh, "<", $ruta) or die "No pude abrir $ruta: $!";
my $primera = 1;
while (my $linea = <$fh>) {
    chomp $linea;
    if ($primera) { $primera = 0; next; }
    my ($time, $open, $high, $low, $close, $volume) = split(/,/, $linea);
    $market->add_candle({
        time => $time, open => $open+0, high => $high+0,
        low => $low+0, close => $close+0, volume => $volume+0,
    });
}
close($fh);

# Construir 5m y 15m
$market->build_timeframes;

# Contar velas por timeframe
for my $tf ('1m','5m','15m') {
    $market->set_timeframe($tf);
    print "Velas en $tf : ", $market->size, "\n";
}
print "\n";

# Primera vela de 5m
$market->set_timeframe('5m');
my $c5 = $market->get_candle(0);
print "Primera vela de 5m:\n";
print "  time=$c5->{time} open=$c5->{open} high=$c5->{high} low=$c5->{low} close=$c5->{close} vol=$c5->{volume}\n\n";

# Primera vela de 15m
$market->set_timeframe('15m');
my $c15 = $market->get_candle(0);
print "Primera vela de 15m:\n";
print "  time=$c15->{time} open=$c15->{open} high=$c15->{high} low=$c15->{low} close=$c15->{close} vol=$c15->{volume}\n";
