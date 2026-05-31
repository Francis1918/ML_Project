#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin";
use Market::MarketData;
use Market::Indicators::ATR;
use Market::IndicatorManager;

# Cargar datos
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
$market->build_timeframes;

# Helper para imprimir valores que pueden ser undef
sub fmt { defined $_[0] ? sprintf("%.6f",$_[0]) : "undef" }

# Crear manager y registrar el ATR
my $mgr = Market::IndicatorManager->new;
$mgr->register('ATR', Market::Indicators::ATR->new(14));

# Construir la serie sobre 1m (update_last hasta ponernos al dia)
$market->set_timeframe('1m');
$mgr->update_last($market) while scalar(@{ $mgr->get('ATR') }) < $market->size;

print "== En 1m ==\n";
print "get('ATR') -> ", scalar(@{ $mgr->get('ATR') }), " valores\n";
my $sl = $mgr->slice_array('ATR', 11, 14);   # incluye warm-up para ver alineacion
print "slice_array('ATR',11,14): [", join(", ", map { fmt($_) } @$sl), "]\n";
print "get('NoExiste') definido? ", (defined $mgr->get('NoExiste') ? "si" : "no (undef)"), "\n\n";

# reset_all
$mgr->reset_all;
print "== Tras reset_all ==\n";
print "get('ATR') -> ", scalar(@{ $mgr->get('ATR') }), " valores\n\n";

# Reconstruir sobre 5m (mismo manager, distinto timeframe)
$market->set_timeframe('5m');
$mgr->update_last($market) while scalar(@{ $mgr->get('ATR') }) < $market->size;
print "== Reconstruido en 5m ==\n";
print "get('ATR') -> ", scalar(@{ $mgr->get('ATR') }), " valores\n";
my $vals5 = $mgr->get('ATR');
print "ATR[13] en 5m: ", fmt($vals5->[13]), "  (distinto al de 1m, como debe ser)\n";
