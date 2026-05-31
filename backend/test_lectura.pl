#!/usr/bin/perl
use strict;
use warnings;

# Ruta al archivo de datos (relativa a la carpeta backend)
my $ruta = "data/2026_03.csv";

# Abrimos el archivo en modo lectura (<). Si falla, el script muere con un mensaje claro.
open(my $fh, "<", $ruta) or die "No pude abrir $ruta: $!";

my $num_linea   = 0;   # Contador de líneas leídas
my $num_velas   = 0;   # Contador de velas (sin contar el encabezado)

while (my $linea = <$fh>) {
    chomp $linea;        # Quita el salto de línea del final
    $num_linea++;

    # La primera línea es el encabezado: la mostramos y saltamos al siguiente ciclo
    if ($num_linea == 1) {
        print "Encabezado detectado: $linea\n\n";
        next;
    }

    # Separamos la línea por comas en sus 6 campos
    my ($time, $open, $high, $low, $close, $volume) = split(/,/, $linea);
    $num_velas++;

    # Mostramos SOLO las primeras 3 velas para no llenar la pantalla
    if ($num_velas <= 3) {
        print "Vela #$num_velas\n";
        print "  Tiempo : $time\n";
        print "  Open   : $open\n";
        print "  High   : $high\n";
        print "  Low    : $low\n";
        print "  Close  : $close\n";
        print "  Volumen: $volume\n";
        print "\n";
    }
}

close($fh);

# Resumen final
print "------------------------------------\n";
print "Total de velas leidas: $num_velas\n";