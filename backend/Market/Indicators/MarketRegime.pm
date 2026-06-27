package Market::Indicators::MarketRegime;

use strict;
use warnings;

# ============================================================
#  Market::Indicators::MarketRegime
#
#  Maquina de estados de contexto de mercado.
#  NO detecta pivots ni liquidez desde cero.
#  Consume salidas de Liquidity.pm y SMC_Structures.pm.
#
#  Estados:
#    UNKNOWN           Sin suficientes datos/pivots.
#    ZONA_INTERNA      Precio en rango local, sin contacto con liquidez relevante.
#    LIQUIDEZ_INTERNA  Precio cerca de BSL/SSL/EQH/EQL de la TF activa.
#    LIQUIDEZ_EXTERNA  Precio cerca de liquidez HTF o major high/low.
#    ZM_MANIPULATION   Zona de ruido: sweeps internos, CHoCH falsos, sin BOS externo.
#    TRANSITION        Evidencia de cambio de control (sweep ext + CHoCH real).
#    TR_BULLISH        Tendencia real alcista validada por BOS/Run externo.
#    TR_BEARISH        Tendencia real bajista validada por BOS/Run externo.
#
#  Reglas criticas:
#    BOS, CHoCH, Sweep, Grab, Run, Volumen y ATR NO son estados.
#    Son condiciones de transicion que modifican el contexto.
#    Liquidez externa tiene prioridad sobre liquidez interna.
#    Ningun calculo usa velas con index > max_visible_index.
# ============================================================

use constant NEAR_EXTERNAL => 0.75;  # distancia <= ATR * factor para LIQUIDEZ_EXTERNA
use constant NEAR_INTERNAL => 0.50;  # distancia <= ATR * factor para LIQUIDEZ_INTERNA

# Tabla de transicion (ver seccion 25.3 del documento de contexto)
#  Prioridad: numero menor = mas importante

my @SCORE_WEIGHTS = (
    { field => 'near_external',   delta => +0.10 },
    { field => 'close_confirmed', delta => +0.10 },
    { field => 'sweep_grab_ext',  delta => +0.15 },
    { field => 'bos_choch_ext',   delta => +0.20 },
    { field => 'vol_high',        delta => +0.05 },
    { field => 'atr_displacement',delta => +0.05 },
);

# ============================================================
sub new { bless {}, shift }

# ============================================================
#  compute : calcula el estado de regimen para cada vela
#
#  Args:
#    candles           : arrayref de velas
#    atr_series        : arrayref de ATR paralelo a candles
#    liquidity_levels  : output de Liquidity->compute->{levels}
#    liquidity_events  : output de Liquidity->compute->{events}
#    structure_events  : output de SMC_Structures->compute->{structures}
#    pivots            : output de SMC_Structures->compute->{pivots}
#    max_visible_index : int (respetar replay)
#    timeframe         : string
#
#  Retorna arrayref de MarketRegimeState (uno por vela)
# ============================================================

sub compute {
    my ($class_or_self, %args) = @_;

    my $candles    = $args{candles}           or die 'MarketRegime::compute: falta candles';
    my $atr_s      = $args{atr_series}        // [];
    my $liq_lvls   = $args{liquidity_levels}  // [];
    my $liq_evts   = $args{liquidity_events}  // [];
    my $struct_evts= $args{structure_events}  // [];
    my $pivots     = $args{pivots}            // [];
    my $max_idx    = $args{max_visible_index} // $#$candles;
    my $tf         = $args{timeframe}         // '1m';

    # Indices de eventos por vela (para lookup O(1))
    my %liq_evt_at;    # swept_index -> evento
    my %struct_evt_at; # break_index -> evento
    for my $ev (@$liq_evts)    { $liq_evt_at{   $ev->{swept_index}  // -999 } = $ev }
    for my $ev (@$struct_evts) { $struct_evt_at{ $ev->{break_index} // -999 } = $ev }

    # Niveles activos indexados por precio para lookup de proximidad
    my @active_internal = grep { ($_->{internal_or_external}//'internal') eq 'internal' } @$liq_lvls;
    my @active_external = grep { ($_->{internal_or_external}//'internal') eq 'external' } @$liq_lvls;

    # Confirmar si hay major high/low disponibles
    my @ext_pivots = grep { ($_->{scope}//'internal') eq 'external' } @$pivots;
    my @ext_highs  = grep { $_->{kind} eq 'high' } @ext_pivots;
    my @ext_lows   = grep { $_->{kind} eq 'low'  } @ext_pivots;

    my $prev_state = 'UNKNOWN';
    my @states;

    for my $i (0 .. $max_idx) {
        last if $i > $#$candles;
        my $c   = $candles->[$i];
        my $atr = $atr_s->[$i] // 0;

        # Eventos en esta vela
        my $liq_ev    = $liq_evt_at{$i};
        my $struct_ev = $struct_evt_at{$i};

        # Nivel de liquidez mas cercano en esta vela
        my ($near_int, $near_ext) = _nearest_liquidity(
            $c->{close}, $atr, \@active_internal, \@active_external, $i
        );

        # Major high/low confirmados hasta esta vela
        my @avail_ext_h = grep { $_->{confirmed_at} <= $i } @ext_highs;
        my @avail_ext_l = grep { $_->{confirmed_at} <= $i } @ext_lows;
        my $last_ext_h  = @avail_ext_h ? $avail_ext_h[-1] : undef;
        my $last_ext_l  = @avail_ext_l ? $avail_ext_l[-1] : undef;

        # Calcular estado base segun proximidad a liquidez
        my ($state, $reason, $score) = _base_state(
            $c, $atr, $near_int, $near_ext, \@avail_ext_h, \@avail_ext_l, $i
        );

        # Aplicar transiciones por eventos de mayor jerarquia
        ($state, $reason, $score) = _apply_transitions(
            $state, $reason, $score,
            $liq_ev, $struct_ev, $prev_state
        );

        # Solo volumen/ATR ajustan score, no crean estados
        $score += 0.05 if _vol_high($c);
        $score  = 1.0  if $score > 1.0;

        push @states, {
            index                  => $i,
            time                   => $c->{time},
            timeframe              => $tf,
            previous_state         => $prev_state,
            state                  => $state,
            reason                 => $reason,
            nearest_liquidity_id   => $near_ext ? $near_ext->{id} : $near_int ? $near_int->{id} : undef,
            nearest_liquidity_scope=> $near_ext ? 'external' : $near_int ? 'internal' : 'none',
            nearest_liquidity_type => $near_ext ? $near_ext->{type} : $near_int ? $near_int->{type} : 'none',
            last_liquidity_event_id=> $liq_ev    ? $liq_ev->{id}    : undef,
            last_structure_event_id=> $struct_ev ? $struct_ev->{id} : undef,
            atr                    => $atr,
            confidence_score       => sprintf("%.2f", $score),
            max_visible_index      => $max_idx,
            replay_safe            => 1,
        };

        $prev_state = $state;
    }

    return \@states;
}

# ============================================================
#  Estado base por proximidad a liquidez
# ============================================================

sub _base_state {
    my ($c, $atr, $near_int, $near_ext, $ext_highs, $ext_lows, $i) = @_;

    return ('UNKNOWN', 'Sin pivots ni liquidez calculados', 0.30)
        unless $atr > 0;

    # LIQUIDEZ_EXTERNA tiene prioridad
    if ($near_ext) {
        return ('LIQUIDEZ_EXTERNA',
                sprintf("Precio cerca de %s externo (dist=%.4f, ATR*%.2f=%.4f)",
                    $near_ext->{type}, $near_ext->{_dist}, NEAR_EXTERNAL, $atr * NEAR_EXTERNAL),
                0.60);
    }

    # Luego major high/low de estructura externa
    for my $eh (@$ext_highs) {
        next unless $eh->{confirmed_at} <= $i;
        if (abs($c->{close} - $eh->{price}) <= $atr * NEAR_EXTERNAL) {
            return ('LIQUIDEZ_EXTERNA',
                    sprintf("Precio cerca de major high externo (%.4f)", $eh->{price}),
                    0.58);
        }
    }
    for my $el (@$ext_lows) {
        next unless $el->{confirmed_at} <= $i;
        if (abs($c->{close} - $el->{price}) <= $atr * NEAR_EXTERNAL) {
            return ('LIQUIDEZ_EXTERNA',
                    sprintf("Precio cerca de major low externo (%.4f)", $el->{price}),
                    0.58);
        }
    }

    # LIQUIDEZ_INTERNA
    if ($near_int) {
        return ('LIQUIDEZ_INTERNA',
                sprintf("Precio cerca de %s interno", $near_int->{type}),
                0.52);
    }

    # ZONA_INTERNA: pivots existen pero precio no esta cerca de liquidez
    return ('ZONA_INTERNA', 'Precio dentro de rango local', 0.45);
}

# ============================================================
#  Transiciones por eventos de mayor jerarquia
# ============================================================

sub _apply_transitions {
    my ($state, $reason, $score, $liq_ev, $struct_ev, $prev_state) = @_;

    # Sweep/Grab externo + CHoCH externo por cierre -> TRANSITION
    if ($liq_ev
        && ($liq_ev->{classification} eq 'SWEEP' || $liq_ev->{classification} eq 'GRAB')
        && ($liq_ev->{internal_or_external}//'internal') eq 'external'
        && $struct_ev
        && $struct_ev->{type} eq 'CHOCH'
        && $struct_ev->{confirmed}
        && ($struct_ev->{scope}//'') eq 'external'
        && $struct_ev->{break_mode} eq 'close') {

        return ('TRANSITION',
                "Sweep/Grab externo ($liq_ev->{classification}) + CHoCH externo $struct_ev->{direction} confirmado",
                $score + 0.30);
    }

    # Run externo + BOS externo -> tendencia real
    if ($liq_ev
        && $liq_ev->{classification} eq 'RUN'
        && ($liq_ev->{internal_or_external}//'internal') eq 'external'
        && $struct_ev
        && $struct_ev->{type} eq 'BOS'
        && $struct_ev->{confirmed}
        && ($struct_ev->{scope}//'') eq 'external'
        && $struct_ev->{break_mode} eq 'close') {

        my $new_state = $struct_ev->{direction} eq 'bullish' ? 'TR_BULLISH' : 'TR_BEARISH';
        return ($new_state,
                "Run externo + BOS $struct_ev->{direction} externo confirmado",
                $score + 0.35);
    }

    # Solo BOS/CHoCH externo confirmado (sin run) -> puede cambiar tendencia
    if ($struct_ev
        && $struct_ev->{confirmed}
        && ($struct_ev->{scope}//'') eq 'external'
        && $struct_ev->{break_mode} eq 'close') {

        if ($struct_ev->{type} eq 'BOS') {
            my $new_state = $struct_ev->{direction} eq 'bullish' ? 'TR_BULLISH' : 'TR_BEARISH';
            return ($new_state,
                    "BOS $struct_ev->{direction} externo confirmado por cierre",
                    $score + 0.25);
        }
        if ($struct_ev->{type} eq 'CHOCH') {
            return ('TRANSITION',
                    "CHoCH $struct_ev->{direction} externo confirmado por cierre",
                    $score + 0.20);
        }
    }

    # Sweep/Grab INTERNO sin confirmacion externa -> ZM_MANIPULATION
    if ($liq_ev
        && ($liq_ev->{classification} eq 'SWEEP' || $liq_ev->{classification} eq 'GRAB')
        && ($liq_ev->{internal_or_external}//'internal') eq 'internal'
        && (!$struct_ev || ($struct_ev->{scope}//'') ne 'external')) {

        return ('ZM_MANIPULATION',
                "Sweep/Grab interno sin confirmacion externa",
                $score + 0.10);
    }

    # Transicion fallida: volver a ZM si estaba en TRANSITION
    if ($prev_state eq 'TRANSITION' && !$struct_ev && !$liq_ev
        && ($state eq 'ZONA_INTERNA' || $state eq 'LIQUIDEZ_INTERNA')) {
        return ('ZM_MANIPULATION', 'TRANSITION sin confirmacion: regresan a manipulacion', $score - 0.05);
    }

    # Heredar TR si ya esta establecido y no hay evento que lo contradiga
    if (($prev_state eq 'TR_BULLISH' || $prev_state eq 'TR_BEARISH')
        && !$struct_ev && !$liq_ev) {
        $reason .= " (continuacion $prev_state)";
        return ($prev_state, $reason, $score + 0.05);
    }

    return ($state, $reason, $score);
}

# ============================================================
#  Helpers
# ============================================================

sub _nearest_liquidity {
    my ($price, $atr, $int_lvls, $ext_lvls, $cur_idx) = @_;
    return (undef, undef) if $atr <= 0;

    my ($best_int, $best_ext, $dist_int, $dist_ext);
    $dist_int = $dist_ext = 9_999_999;

    for my $lv (@$ext_lvls) {
        next unless $lv->{start_index} <= $cur_idx;
        next unless $lv->{active};
        my $d = abs($price - $lv->{price});
        if ($d < $dist_ext && $d <= $atr * NEAR_EXTERNAL) {
            $dist_ext = $d; $best_ext = { %$lv, _dist => $d };
        }
    }

    for my $lv (@$int_lvls) {
        next unless $lv->{start_index} <= $cur_idx;
        next unless $lv->{active};
        my $d = abs($price - $lv->{price});
        if ($d < $dist_int && $d <= $atr * NEAR_INTERNAL) {
            $dist_int = $d; $best_int = { %$lv, _dist => $d };
        }
    }

    return ($best_int, $best_ext);
}

sub _vol_high {
    my ($c) = @_;
    # Placeholder: marcamos volumen alto si el volumen existe y es > 0
    # En implementacion completa se compara con rolling average
    return ($c->{volume} // 0) > 0 ? 0 : 0;  # desactivado sin referencia de media
}

1;
