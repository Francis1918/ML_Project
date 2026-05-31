package Market::Indicators::ATR;

use strict;
use warnings;

# ============================================================
#  Market::Indicators::ATR
#  Average True Range. Mide volatilidad.
#  Usa suavizado de Wilder (RMA), igual que TradingView:
#    - True Range (TR) por vela.
#    - Primer ATR = promedio simple de los primeros 'period' TR.
#    - ATR siguiente = (ATR_anterior * (period-1) + TR) / period.
#  Calculo incremental: update_last procesa UNA vela nueva por llamada.
# ============================================================

sub new {
    my ($class, $period) = @_;
    my $self = {
        period    => $period,
        values    => [],      # serie de ATR, paralela a las velas (undef en warm-up)
        _tr_sum   => 0,       # acumulador para el promedio inicial
        _count    => 0,       # velas procesadas
        _prev_atr => undef,   # ultimo ATR (para la recursion de Wilder)
    };
    bless $self, $class;
    return $self;
}

# --- update_last --------------------------------------------
# Input : $market -> objeto MarketData (timeframe activo)
# Output: (nada)
# Procesa la siguiente vela no procesada (la ultima cuando se
# llama justo tras agregarla) y agrega su ATR a la serie.
sub update_last {
    my ($self, $market) = @_;
    my $n = $self->{period};

    my $idx = scalar @{ $self->{values} };   # indice de la vela a procesar
    return if $idx >= $market->size;          # ya estamos al dia

    my $cur = $market->get_candle($idx);

    # --- True Range ---
    my $tr;
    if ($idx == 0) {
        $tr = $cur->{high} - $cur->{low};     # primera vela: sin cierre previo
    }
    else {
        my $prev_close = $market->get_candle($idx - 1)->{close};
        my $hl = $cur->{high} - $cur->{low};
        my $hc = abs($cur->{high} - $prev_close);
        my $lc = abs($cur->{low}  - $prev_close);
        $tr = $hl;
        $tr = $hc if $hc > $tr;
        $tr = $lc if $lc > $tr;
    }

    # --- ATR (Wilder) ---
    $self->{_tr_sum} += $tr;
    $self->{_count}  += 1;

    my $atr;
    if ($self->{_count} < $n) {
        $atr = undef;                                 # warm-up
    }
    elsif ($self->{_count} == $n) {
        $atr = $self->{_tr_sum} / $n;                 # primer ATR = SMA de n TR
        $self->{_prev_atr} = $atr;
    }
    else {
        $atr = ( $self->{_prev_atr} * ($n - 1) + $tr ) / $n;   # recursion de Wilder
        $self->{_prev_atr} = $atr;
    }

    push @{ $self->{values} }, $atr;
    return;
}

# --- get_values ---------------------------------------------
sub get_values {
    my ($self) = @_;
    return $self->{values};
}

# --- reset --------------------------------------------------
sub reset {
    my ($self) = @_;
    $self->{values}    = [];
    $self->{_tr_sum}   = 0;
    $self->{_count}    = 0;
    $self->{_prev_atr} = undef;
    return;
}

1;
