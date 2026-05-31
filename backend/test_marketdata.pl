#!/usr/bin/perl
use strict;
use warnings;

# Permite encontrar el modulo Market::MarketData ubicado en la
# misma carpeta de este script (backend/Market/MarketData.pm).
use FindBin;
use lib "$FindBin::Bin";

use Market::MarketData;

# 1) Creamos el objeto que almacenara las velas
my $market = Market::MarketData->new;

# 2) Leemos el CSV y agregamos cada vela con add_candle
my $ruta = "$FindBin::Bin/data/2026_03.csv";
open(my $fh, "<", $ruta) or die "No pude abrir $ruta: $!";

my $primera = 1;
while (my $linea = <$fh>) {
    chomp $linea;

    # Saltamos el encabezado
    if ($primera) { $primera = 0; next; }

    my ($time, $open, $high, $low, $close, $volume) = split(/,/, $linea);

    # Construimos la vela como hash y la agregamos.
    # El "+ 0" fuerza que se guarden como numeros (util luego para JSON).
    $market->add_candle({
        time   => $time,
        open   => $open  + 0,
        high   => $high  + 0,
        low    => $low   + 0,
        close  => $close + 0,
        volume => $volume + 0,
    });
}
close($fh);

# 3) Verificamos usando los metodos de la clase
print "Total de velas (size)      : ", $market->size,       "\n";
print "Indice de la ultima (last) : ", $market->last_index, "\n\n";

my $v0 = $market->get_candle(0);
print "Primera vela (indice 0):\n";
print "  time = $v0->{time}\n";
print "  open = $v0->{open}\n";
print "  close= $v0->{close}\n\n";

my $ult = $market->last_candle;
print "Ultima vela:\n";
print "  time = $ult->{time}\n";
print "  open = $ult->{open}\n";
print "  close= $ult->{close}\n";