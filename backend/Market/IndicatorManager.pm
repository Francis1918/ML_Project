package Market::IndicatorManager;

use strict;
use warnings;

# ============================================================
#  Market::IndicatorManager
#  Gestiona varios indicadores de forma DESACOPLADA: registrar,
#  actualizar, consultar. No conoce el render ni el chart.
# ============================================================

sub new {
    my ($class) = @_;
    my $self = { indicators => {} };   # nombre => objeto indicador
    bless $self, $class;
    return $self;
}

# --- register -----------------------------------------------
# Input : $name (string), $indicator (objeto con update_last/get_values/reset)
# Output: (nada). Permite extensibilidad: cualquier indicador
#         que cumpla la interfaz se puede registrar por nombre.
sub register {
    my ($self, $name, $indicator) = @_;
    $self->{indicators}{$name} = $indicator;
    return;
}

# --- update_last --------------------------------------------
# Input : $market (MarketData)
# Output: (nada). Actualiza TODOS los indicadores con la ultima
#         vela. Calculo incremental.
sub update_last {
    my ($self, $market) = @_;
    for my $ind (values %{ $self->{indicators} }) {
        $ind->update_last($market);
    }
    return;
}

# --- get ----------------------------------------------------
# Input : $name
# Output: serie COMPLETA de valores del indicador (arrayref), o undef.
sub get {
    my ($self, $name) = @_;
    my $ind = $self->{indicators}{$name};
    return undef unless $ind;
    return $ind->get_values;
}

# --- slice_array --------------------------------------------
# Input : $name, $start, $end (indices inclusivos)
# Output: porcion de la serie (arrayref, recortada a limites validos).
#         Sincroniza el indicador con la ventana visible del chart.
sub slice_array {
    my ($self, $name, $start, $end) = @_;
    my $vals = $self->get($name);
    return [] unless $vals;

    my $last = $#$vals;
    return [] if $last < 0;
    $start = 0     if $start < 0;
    $end   = $last if $end > $last;
    return [] if $start > $end;

    return [ @{$vals}[ $start .. $end ] ];
}

# --- reset_all ----------------------------------------------
# Input : (nada)
# Output: (nada). Reinicia todos los indicadores (util al cambiar
#         de timeframe, antes de reconstruir la serie).
sub reset_all {
    my ($self) = @_;
    for my $ind (values %{ $self->{indicators} }) {
        $ind->reset;
    }
    return;
}

1;
