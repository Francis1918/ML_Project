#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin";
use Market::MarketData;

my $market = Market::MarketData->new;

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
$market->build_timeframes;

# ---- get_slice (sobre 5m) ----
$market->set_timeframe('5m');
my $slice = $market->get_slice(0, 2);
print "get_slice(0,2) en 5m -> ", scalar(@$slice), " velas:\n";
for my $c (@$slice) {
    print "   $c->{time}  close=$c->{close}\n";
}
my $tail = $market->get_slice(5975, 999999);
print "get_slice(5975, 999999) en 5m -> ", scalar(@$tail), " velas (recortado al final)\n\n";

# ---- get_timestamp ----
print "get_timestamp(0) en 5m -> ", $market->get_timestamp(0), "\n\n";

# ---- merge_delta_row ----
$market->set_timeframe('1m');
print "Antes del merge -> size 1m = ", $market->size, ", ultimo close = ", $market->last_candle->{close}, "\n";
my $ult_time = $market->last_candle->{time};
$market->merge_delta_row({
    time => $ult_time, open => 27632, high => 27999,
    low => 27600, close => 27777, volume => 50,
});
print "Tras UPDATE (mismo time) -> size = ", $market->size, ", ultimo close = ", $market->last_candle->{close}, "\n";
$market->merge_delta_row({
    time => "2026-05-01T00:00:00-05:00", open => 27800, high => 27810,
    low => 27790, close => 27805, volume => 12,
});
print "Tras INSERT (time nuevo) -> size = ", $market->size, ", ultimo close = ", $market->last_candle->{close}, "\n\n";

# ---- compute_time_anchors (sobre 5m) ----
$market->set_timeframe('5m');
my $anchors = $market->compute_time_anchors;
print "compute_time_anchors en 5m -> ", scalar(@$anchors), " anclas. Primeras 3:\n";
for my $a (@{$anchors}[0..2]) {
    print "   idx=$a->{index} time=$a->{time} hour=$a->{hour} new_day=$a->{is_new_day}\n";
}
