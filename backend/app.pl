#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin";

use Mojolicious::Lite;

use Market::MarketData;
use Market::Indicators::ATR;
use Market::IndicatorManager;

# ============================================================
#  app.pl  -- Punto de entrada / servidor del sistema.
#  - Lee el CSV (1m) y construye 5m/15m.
#  - Calcula el ATR de cada timeframe (via IndicatorManager).
#  - Sirve el frontend (../frontend) y expone una API JSON.
# ============================================================

# --- Servir archivos estaticos del frontend ---
push @{ app->static->paths }, "$FindBin::Bin/../frontend";

# --- Configuracion ---
my $CSV    = "$FindBin::Bin/data/2026_03.csv";
my @TFS    = ('1m', '5m', '15m');
my $PERIOD = 14;

# --- 1) Leer el CSV y poblar MarketData (1m) ---
my $market = Market::MarketData->new;
open(my $fh, "<", $CSV) or die "No pude abrir $CSV: $!";
my $primera = 1;
while (my $linea = <$fh>) {
    chomp $linea;
    if ($primera) { $primera = 0; next; }
    my ($t,$o,$h,$l,$c,$v) = split(/,/, $linea);
    $market->add_candle({ time=>$t, open=>$o+0, high=>$h+0, low=>$l+0, close=>$c+0, volume=>$v+0 });
}
close($fh);

# --- 2) Construir timeframes derivados ---
$market->build_timeframes;

# --- 3) Manager con ATR registrado ---
my $mgr = Market::IndicatorManager->new;
$mgr->register('ATR', Market::Indicators::ATR->new($PERIOD));

# --- 4) Precomputar candles + ATR + anchors por timeframe (cache) ---
my %CACHE;
for my $tf (@TFS) {
    $market->set_timeframe($tf);
    $mgr->reset_all;
    $mgr->update_last($market) while scalar(@{ $mgr->get('ATR') }) < $market->size;

    $CACHE{$tf} = {
        timeframe => $tf,
        candles   => $market->get_slice(0, $market->last_index),
        atr       => [ @{ $mgr->get('ATR') } ],
        anchors   => $market->compute_time_anchors,
    };
}
app->log->info("Datos listos: " . join(", ", map { "$_=".scalar(@{$CACHE{$_}{candles}}) } @TFS));

# ============================================================
#  Rutas
# ============================================================

# Pagina principal -> index.html del frontend
get '/' => sub {
    my $c = shift;
    $c->reply->static('index.html');
};

# Salud / resumen (JSON pequeno, util para verificar)
get '/api/info' => sub {
    my $c = shift;
    my %counts;
    for my $tf (@TFS) {
        $counts{$tf} = {
            candles => scalar(@{ $CACHE{$tf}{candles} }),
            atr     => scalar(@{ $CACHE{$tf}{atr} }),
            anchors => scalar(@{ $CACHE{$tf}{anchors} }),
        };
    }
    $c->render(json => {
        ok          => \1,
        period_atr  => $PERIOD,
        timeframes  => \@TFS,
        counts      => \%counts,
        last_atr_1m => $CACHE{'1m'}{atr}[-1],
    });
};

# Datos completos de un timeframe: candles + atr + anchors
get '/api/candles' => sub {
    my $c  = shift;
    my $tf = $c->param('tf') // '1m';
    unless (exists $CACHE{$tf}) {
        return $c->render(json => { error => "timeframe invalido: $tf" }, status => 400);
    }
    $c->render(json => $CACHE{$tf});
};

app->start;
