package Market::Indicators::Liquidity;

use strict;
use warnings;
use List::Util qw(max min);

# ============================================================
#  Market::Indicators::Liquidity
#
#  Detecta niveles de liquidez y los modela con una maquina
#  de estados determinista. No dibuja; solo calcula y exporta.
#
#  Niveles detectados:
#    BSL  Buy Side Liquidity  (encima de Swing Highs / EQH)
#    SSL  Sell Side Liquidity (debajo de Swing Lows  / EQL)
#    EQH  Equal Highs  (tolerancia = ATR * 0.10)
#    EQL  Equal Lows
#
#  Maquina de estados por nivel:
#    DETECTED -> SWEPT -> ACCEPTANCE -> RESOLVED (RUN)
#                      -> RECLAIMED  -> RESOLVED (GRAB o SWEEP)
#
#  Clasificacion final del evento:
#    SWEEP : precio cruzo y regreso sin aceptacion
#    GRAB  : retorno rapido (<=3 velas)
#    RUN   : >= N cierres consecutivos fuera del nivel
#
#  Regla de Replay:
#    Ningun calculo usa velas con index > max_visible_index.
# ============================================================

# N de cierres consecutivos para clasificar como RUN
use constant RUN_BARS   => 3;
# Ventana de velas para clasificar GRAB vs SWEEP
use constant GRAB_BARS  => 3;
# Parametro k para Swing High/Low (confirmacion requiere i+k velas)
use constant SWING_K    => 3;
# Tolerancia EQH/EQL como multiplicador de ATR
use constant EQ_FACTOR  => 0.10;

my $NEXT_ID = 1;
sub _new_id { return 'LQ_' . sprintf('%04d', $NEXT_ID++) }

# ============================================================
sub new {
    my ($class) = @_;
    bless {
        levels => [],   # ArrayRef de LiquidityLevel
        events => [],   # ArrayRef de LiquidityEvent
    }, $class;
}

# ============================================================
#  Interface compatible con IndicatorManager
# ============================================================

sub update_last {
    my ($self, $market, $atr_series, $max_visible_index, $timeframe, $ext_levels) = @_;

    # Atr_series: arrayref paralelo a candles (undef durante warm-up)
    # ext_levels: niveles externos (HTF) opcionales para marcar scope=external

    my $idx = $self->{_last_processed} // -1;
    $idx++;

    return if $idx > $max_visible_index;
    return if $idx >= $market->size;

    my $candle = $market->get_candle($idx);
    my $atr    = defined $atr_series ? $atr_series->[$idx] : undef;

    $self->{_last_processed} = $idx;

    # 1. Confirmar nuevos Swing High/Low si ya hay suficientes velas
    $self->_detect_swing_points($market, $idx, $atr, $max_visible_index, $timeframe);

    # 2. Avanzar maquina de estados de niveles existentes
    $self->_advance_states($candle, $idx, $max_visible_index);

    return;
}

sub reset {
    my ($self) = @_;
    $self->{levels}          = [];
    $self->{events}          = [];
    $self->{_last_processed} = undef;
    $self->{_swings}         = [];
    $self->{_volume_source_indexes} = {};
    $NEXT_ID = 1;
    return;
}

sub get_values { return [] }   # compatibilidad con IndicatorManager (no aplica)

# ============================================================
#  Calculo completo para un slice de velas (modo batch)
#  Retorna { levels => [...], events => [...] }
# ============================================================

sub compute {
    my ($class_or_self, %args) = @_;

    my $candles           = $args{candles}           or die 'Liquidity::compute: falta candles';
    my $atr_series        = $args{atr_series}        // [];
    my $max_visible_index = $args{max_visible_index} // $#$candles;
    my $timeframe         = $args{timeframe}         // '1m';
    my $ext_levels        = $args{ext_levels}        // [];  # niveles HTF para marcar external
    my $volume_sources    = $args{volume_sources}    // {};  # { '1m'=>[...], '5m'=>[...], '15m'=>[...] }
    my $volume_until_time = $args{volume_until_time};         # corte replay-safe opcional

    my $self = ref($class_or_self) ? $class_or_self : $class_or_self->new;
    $self->reset;

    my $VOL_WIN = 14;
    my @vol_avg;
    my $vol_sum = 0;
    for my $i (0 .. $#$candles) {
        $vol_sum += ($candles->[$i]{volume} // 0);
        $vol_sum -= ($candles->[$i - $VOL_WIN]{volume} // 0) if $i >= $VOL_WIN;
        my $cnt = $i + 1 < $VOL_WIN ? $i + 1 : $VOL_WIN;
        $vol_avg[$i] = $cnt > 0 ? $vol_sum / $cnt : 1;
    }
    $self->{_vol_avg}           = \@vol_avg;
    $self->{_candles}           = $candles;
    $self->{_timeframe}         = $timeframe;
    $self->{_volume_sources}    = $volume_sources;
    $self->{_volume_source_indexes} = _prepare_volume_source_indexes($volume_sources);
    $self->{_volume_until_time} = $volume_until_time;

    # Fase 1: detectar todos los swings y crear niveles BSL/SSL/EQH/EQL
    my @swings = _find_swing_points($candles, $max_visible_index);
    $self->_create_levels_from_swings(\@swings, $candles, $atr_series, $timeframe, $ext_levels);

    # Fase 2: avanzar maquina de estados solo sobre niveles vivos.
    my @levels_by_start = sort { $a->{start_index} <=> $b->{start_index} } @{ $self->{levels} };
    my @active_levels;
    my $next_level = 0;
    for my $i (0 .. $max_visible_index) {
        last if $i > $#$candles;
        while ($next_level <= $#levels_by_start
            && $levels_by_start[$next_level]{start_index} <= $i) {
            push @active_levels, $levels_by_start[$next_level++];
        }
        my $c = $candles->[$i];
        $self->_advance_state_list($c, $i, \@active_levels);
        @active_levels = grep { $_->{active} } @active_levels if @active_levels;
    }

    return {
        levels => $self->{levels},
        events => $self->{events},
    };
}

# ============================================================
#  Deteccion de Swing Highs y Swing Lows
# ============================================================

sub _find_swing_points {
    my ($candles, $max_idx) = @_;
    my @swings;
    my $k = SWING_K;

    for my $i ($k .. $max_idx) {
        last if $i + $k > $max_idx;  # necesitamos k velas a la derecha

        # Swing High: high[i] es maximo local en ventana [i-k, i+k]
        my $is_sh = 1;
        for my $j (1 .. $k) {
            if ($candles->[$i-$j]{high} >= $candles->[$i]{high}
             || $candles->[$i+$j]{high} >= $candles->[$i]{high}) {
                $is_sh = 0; last;
            }
        }
        if ($is_sh) {
            push @swings, {
                kind              => 'high',
                index             => $i,
                price             => $candles->[$i]{high},
                time              => $candles->[$i]{time},
                confirmed_at      => $i + $k,
                confirmed_time    => $candles->[$i + $k]{time},
                broke_structure   => 0,
                strength          => 'unknown',
            };
        }

        # Swing Low: low[i] es minimo local en ventana [i-k, i+k]
        my $is_sl = 1;
        for my $j (1 .. $k) {
            if ($candles->[$i-$j]{low} <= $candles->[$i]{low}
             || $candles->[$i+$j]{low} <= $candles->[$i]{low}) {
                $is_sl = 0; last;
            }
        }
        if ($is_sl) {
            push @swings, {
                kind              => 'low',
                index             => $i,
                price             => $candles->[$i]{low},
                time              => $candles->[$i]{time},
                confirmed_at      => $i + $k,
                confirmed_time    => $candles->[$i + $k]{time},
                broke_structure   => 0,
                strength          => 'unknown',
            };
        }
    }

    return sort { $a->{index} <=> $b->{index} } @swings;
}

# ============================================================
#  Creacion de niveles BSL/SSL/EQH/EQL desde swings
# ============================================================

sub _create_levels_from_swings {
    my ($self, $swings, $candles, $atr_series, $timeframe, $ext_levels) = @_;

    my @highs = grep { $_->{kind} eq 'high' } @$swings;
    my @lows  = grep { $_->{kind} eq 'low'  } @$swings;

    # --- BSL: encima de cada Swing High ---
    for my $sh (@highs) {
        my $atr = _atr_at($atr_series, $sh->{index}) // 0;
        push @{ $self->{levels} }, {
            id                 => _new_id(),
            type               => 'BSL',
            origin             => 'swing',
            timeframe          => $timeframe,
            price              => $sh->{price},
            start_index        => $sh->{confirmed_at},
            start_time         => $sh->{confirmed_time},
            pivot_time         => $sh->{time},
            end_index          => undef,
            end_time           => undef,
            pivots             => [$sh],
            tolerance          => $atr * EQ_FACTOR,
            state              => 'DETECTED',
            active             => 1,
            internal_or_external => _scope($sh->{price}, $ext_levels),
            volume_weights     => _vol_weight($self, $candles, $sh->{index}),
            _sweep_index       => undef,
            _consecutive_out   => 0,
            _sweep_candidate   => undef,
        };
    }

    # --- SSL: debajo de cada Swing Low ---
    for my $sl (@lows) {
        my $atr = _atr_at($atr_series, $sl->{index}) // 0;
        push @{ $self->{levels} }, {
            id                 => _new_id(),
            type               => 'SSL',
            origin             => 'swing',
            timeframe          => $timeframe,
            price              => $sl->{price},
            start_index        => $sl->{confirmed_at},
            start_time         => $sl->{confirmed_time},
            pivot_time         => $sl->{time},
            end_index          => undef,
            end_time           => undef,
            pivots             => [$sl],
            tolerance          => $atr * EQ_FACTOR,
            state              => 'DETECTED',
            active             => 1,
            internal_or_external => _scope($sl->{price}, $ext_levels),
            volume_weights     => _vol_weight($self, $candles, $sl->{index}),
            _sweep_index       => undef,
            _consecutive_out   => 0,
            _sweep_candidate   => undef,
        };
    }

    _create_equal_levels($self, \@highs, 'EQH', $candles, $atr_series, $timeframe, $ext_levels);
    _create_equal_levels($self, \@lows,  'EQL', $candles, $atr_series, $timeframe, $ext_levels);

    return;
}

sub _create_equal_levels {
    my ($self, $points, $type, $candles, $atr_series, $timeframe, $ext_levels) = @_;
    return unless @$points >= 2;

    my $MAX_LOOKBACK_SWINGS = 120;
    for my $j (1 .. $#$points) {
        my $cur = $points->[$j];
        my $atr = _atr_at($atr_series, $cur->{index}) // 0;
        next unless $atr > 0;
        my $tol = $atr * EQ_FACTOR;

        my ($best, $best_dist);
        my $seen = 0;
        for (my $i = $j - 1; $i >= 0 && $seen < $MAX_LOOKBACK_SWINGS; $i--, $seen++) {
            my $prev = $points->[$i];
            my $dist = abs($prev->{price} - $cur->{price});
            next if $dist > $tol;
            if (!defined $best_dist || $dist < $best_dist) {
                $best = $prev;
                $best_dist = $dist;
            }
        }
        next unless $best;

        my $price = ($best->{price} + $cur->{price}) / 2;
        push @{ $self->{levels} }, {
            id                 => _new_id(),
            type               => $type,
            origin             => 'equal_level',
            timeframe          => $timeframe,
            price              => $price,
            start_index        => $cur->{confirmed_at},
            start_time         => $cur->{confirmed_time},
            pivot_time         => $cur->{time},
            end_index          => undef,
            end_time           => undef,
            pivots             => [$best, $cur],
            tolerance          => $tol,
            state              => 'DETECTED',
            active             => 1,
            internal_or_external => _scope($price, $ext_levels),
            volume_weights     => _vol_weight($self, $candles, $cur->{index}),
            _sweep_index       => undef,
            _consecutive_out   => 0,
            _sweep_candidate   => undef,
        };
    }
}

# ============================================================
#  Maquina de estados: avance por vela
# ============================================================

sub _advance_states {
    my ($self, $candle, $idx, $max_visible_index) = @_;
    $self->_advance_state_list($candle, $idx, $self->{levels});
}

sub _advance_state_list {
    my ($self, $candle, $idx, $levels) = @_;

    for my $lv (@$levels) {
        next unless $lv->{active};
        next if $idx < $lv->{start_index};   # nivel no existe aun

        my $state = $lv->{state};
        my $price = $lv->{price};

        # ---- DETECTED: vigilar si el precio cruza el nivel ----
        if ($state eq 'DETECTED') {
            my $crossed = ($lv->{type} eq 'BSL' || $lv->{type} eq 'EQH')
                ? $candle->{high} > $price
                : $candle->{low}  < $price;

            if ($crossed) {
                $lv->{state}            = 'SWEPT';
                $lv->{_sweep_index}     = $idx;
                $lv->{_sweep_candidate} = {
                    swept_index => $idx,
                    swept_price => ($lv->{type} eq 'BSL' || $lv->{type} eq 'EQH')
                                   ? $candle->{high} : $candle->{low},
                    close_price => $candle->{close},
                };
                $lv->{_consecutive_out} = 0;
            }
        }

        # ---- SWEPT: determinar RUN o retorno ----
        elsif ($state eq 'SWEPT') {
            my $is_bsl = ($lv->{type} eq 'BSL' || $lv->{type} eq 'EQH');

            # Verificar si el cierre sigue fuera del nivel (aceptacion)
            my $close_out = $is_bsl
                ? $candle->{close} > $price
                : $candle->{close} < $price;

            if ($close_out) {
                $lv->{_consecutive_out}++;
                if ($lv->{_consecutive_out} >= RUN_BARS) {
                    # Aceptacion: es un RUN
                    $lv->{state}     = 'RESOLVED';
                    $lv->{active}    = 0;
                    $lv->{end_index} = $idx;
                    $lv->{end_time}  = $candle->{time};
                    $self->_emit_event($lv, 'RUN', $idx, $candle);
                }
            }
            else {
                # El precio volvio al rango
                $lv->{state} = 'RECLAIMED';
            }
        }

        # ---- RECLAIMED: clasificar GRAB o SWEEP ----
        elsif ($state eq 'RECLAIMED') {
            my $bars_since = $idx - ($lv->{_sweep_index} // $idx);
            my $classification = $bars_since <= GRAB_BARS ? 'GRAB' : 'SWEEP';

            $lv->{state}     = 'RESOLVED';
            $lv->{active}    = 0;
            $lv->{end_index} = $idx;
            $lv->{end_time}  = $candle->{time};
            $self->_emit_event($lv, $classification, $idx, $candle);
        }
    }
}

sub _emit_event {
    my ($self, $lv, $classification, $resolved_idx, $candle) = @_;

    my $sc = $lv->{_sweep_candidate} // {};

    # Efecto proyectado segun clasificacion
    my $effect = $classification eq 'RUN'   ? 'BOS_WEIGHT'
               : $classification eq 'GRAB'  ? 'REVERSAL_ALERT'
               :                              'CHOCH_WEIGHT';   # SWEEP

    # Volume weight del sweep: candle donde ocurrio el barrido
    my $sweep_idx = $sc->{swept_index} // $resolved_idx;
    my $sweep_vw  = _vol_weight($self, $self->{_candles}, $sweep_idx);
    my $sweep_time = (defined $sweep_idx && $self->{_candles} && $sweep_idx <= $#{ $self->{_candles} })
        ? $self->{_candles}[$sweep_idx]{time}
        : undef;

    push @{ $self->{events} }, {
        id                 => _new_id(),
        level_id           => $lv->{id},
        timeframe          => $lv->{timeframe},
        direction          => ($lv->{type} eq 'BSL' || $lv->{type} eq 'EQH') ? 'up' : 'down',
        swept_index        => $sc->{swept_index},
        swept_time         => $sweep_time,
        swept_price        => $sc->{swept_price},
        close_price        => $sc->{close_price},
        state_path         => ['DETECTED', 'SWEPT',
                               ($classification eq 'RUN' ? 'ACCEPTANCE' : 'RECLAIMED'),
                               'RESOLVED'],
        classification     => $classification,
        resolved_index     => $resolved_idx,
        resolved_time      => $candle->{time},
        confirmation_bars  => ($resolved_idx - ($sc->{swept_index} // $resolved_idx)),
        related_fvg_ids    => [],
        projected_effect   => $effect,
        internal_or_external => $lv->{internal_or_external},
        volume_weights     => {
            at_level => $lv->{volume_weights},
            at_sweep => $sweep_vw,
        },
    };
}

# ============================================================
#  Helpers
# ============================================================

sub _atr_at {
    my ($atr_series, $idx) = @_;
    return undef unless defined $atr_series && defined $atr_series->[$idx];
    return $atr_series->[$idx];
}

# Retorna hash de pesado de volumen. Mantiene los campos legacy
# vol_at/vol_avg/vol_ratio, pero agrega persistencia multi-temporal
# obligatoria para 1m, 5m y 15m: m1, m5, m15, score, estimated.
sub _vol_weight {
    my ($self, $candles, $idx) = @_;
    return _empty_vol_weight()
        unless defined $candles && defined $idx && $idx <= $#$candles;

    my $vol_avg = $self->{_vol_avg} // [];
    my $vol_at  = $candles->[$idx]{volume} // 0;
    my $avg     = $vol_avg->[$idx] || 1;

    my $legacy = {
        vol_at    => $vol_at + 0,
        vol_avg   => sprintf("%.2f", $avg) + 0,
        vol_ratio => sprintf("%.2f", $vol_at / $avg) + 0,
    };

    my $start_time = $candles->[$idx]{time};
    my $end_time   = _add_minutes_iso($start_time, _tf_minutes($self->{_timeframe} // '1m'));
    if (defined $self->{_volume_until_time} && $self->{_volume_until_time} lt $end_time) {
        $end_time = $self->{_volume_until_time};
    }

    my $sources = $self->{_volume_sources} // {};
    my $source_indexes = $self->{_volume_source_indexes} // {};
    my $m1  = _source_volume_weight($sources->{'1m'},  $start_time, $end_time, $source_indexes->{'1m'});
    my $m5  = _source_volume_weight($sources->{'5m'},  $start_time, $end_time, $source_indexes->{'5m'});
    my $m15 = _source_volume_weight($sources->{'15m'}, $start_time, $end_time, $source_indexes->{'15m'});

    # Score compacto 0..1 para priorizar eventos con participacion relativa alta.
    # Se basa en ratios frente al promedio local de cada fuente disponible.
    my @ratios = grep { defined $_ } map { $_->{ratio} } ($m1, $m5, $m15);
    my $ratio_avg = @ratios ? _sum(@ratios) / scalar(@ratios) : ($legacy->{vol_ratio} // 0);
    my $score = $ratio_avg <= 0 ? 0 : $ratio_avg / 3.0;
    $score = 1 if $score > 1;

    my $estimated = ($m1->{estimated} || $m5->{estimated} || $m15->{estimated}) ? 1 : 0;

    return {
        %$legacy,
        m1        => $m1,
        m5        => $m5,
        m15       => $m15,
        score     => sprintf("%.3f", $score) + 0,
        estimated => $estimated,
    };
}

sub _empty_vol_weight {
    my $empty = { volume => 0, avg => 0, ratio => 0, candles => 0, estimated => 1 };
    return {
        vol_at    => 0,
        vol_avg   => 0,
        vol_ratio => 0,
        m1        => { %$empty },
        m5        => { %$empty },
        m15       => { %$empty },
        score     => 0,
        estimated => 1,
    };
}

sub _prepare_volume_source_indexes {
    my ($sources) = @_;
    return {} unless $sources;

    my %indexes;
    for my $tf (qw(1m 5m 15m)) {
        my $source = $sources->{$tf};
        next unless $source && @$source;
        $indexes{$tf} = _prepare_volume_source_index($source);
    }
    return \%indexes;
}

sub _prepare_volume_source_index {
    my ($source) = @_;
    my (@times, @prefix);
    $prefix[0] = 0;

    for my $i (0 .. $#$source) {
        my $c = $source->[$i];
        $times[$i] = $c->{time} // '';
        $prefix[$i + 1] = $prefix[$i] + ($c->{volume} // 0);
    }

    return {
        source => $source,
        times  => \@times,
        prefix => \@prefix,
    };
}

sub _source_volume_weight {
    my ($source, $start_time, $end_time, $source_index) = @_;
    return { volume => 0, avg => 0, ratio => 0, candles => 0, estimated => 1 }
        unless $source && @$source && defined $start_time && defined $end_time;

    return _source_volume_weight_indexed($source_index, $start_time, $end_time)
        if $source_index && $source_index->{times} && @{ $source_index->{times} };

    my ($sum, $cnt) = (0, 0);
    for my $c (@$source) {
        my $t = $c->{time};
        next unless defined $t;
        next if $t lt $start_time;
        last if $t ge $end_time;
        $sum += $c->{volume} // 0;
        $cnt++;
    }

    my $estimated = 0;
    if ($cnt == 0) {
        # Si el TF fuente es mayor que la ventana activa, usar la vela fuente
        # contenedora como aproximacion marcada. Esto mantiene estructura m1/m5/m15.
        my $container = _containing_candle($source, $start_time);
        if ($container) {
            $sum = $container->{volume} // 0;
            $cnt = 1;
            $estimated = 1;
        }
    }

    my $avg = _avg_volume_near($source, $start_time, 14) || 1;
    my $ratio = $avg > 0 ? $sum / $avg : 0;

    return {
        volume    => sprintf("%.2f", $sum) + 0,
        avg       => sprintf("%.2f", $avg) + 0,
        ratio     => sprintf("%.3f", $ratio) + 0,
        candles   => $cnt + 0,
        estimated => $estimated ? 1 : 0,
    };
}

sub _source_volume_weight_indexed {
    my ($idx, $start_time, $end_time) = @_;
    my $source = $idx->{source};
    my $times  = $idx->{times};
    my $prefix = $idx->{prefix};
    return { volume => 0, avg => 0, ratio => 0, candles => 0, estimated => 1 }
        unless $source && @$source && $times && @$times && $prefix;

    my $from = _lower_bound_time($times, $start_time);
    my $to   = _lower_bound_time($times, $end_time);
    my $cnt  = $to - $from;
    my $sum  = $prefix->[$to] - $prefix->[$from];

    my $estimated = 0;
    if ($cnt == 0) {
        my $pos = _upper_bound_time($times, $start_time) - 1;
        if ($pos >= 0) {
            $sum = $source->[$pos]{volume} // 0;
            $cnt = 1;
            $estimated = 1;
        }
    }

    my $avg = _avg_volume_near_indexed($idx, $start_time, 14) || 1;
    my $ratio = $avg > 0 ? $sum / $avg : 0;

    return {
        volume    => sprintf("%.2f", $sum) + 0,
        avg       => sprintf("%.2f", $avg) + 0,
        ratio     => sprintf("%.3f", $ratio) + 0,
        candles   => $cnt + 0,
        estimated => $estimated ? 1 : 0,
    };
}

sub _avg_volume_near_indexed {
    my ($idx, $time, $win) = @_;
    my $times  = $idx->{times};
    my $prefix = $idx->{prefix};
    return 0 unless $times && @$times && $prefix;

    my $pos = _upper_bound_time($times, $time) - 1;
    $pos = 0 if $pos < 0;
    my $from = $pos >= ($win - 1) ? $pos - $win + 1 : 0;
    my $cnt = $pos - $from + 1;
    my $sum = $prefix->[$pos + 1] - $prefix->[$from];
    return $cnt ? $sum / $cnt : 0;
}

sub _lower_bound_time {
    my ($times, $target) = @_;
    my ($lo, $hi) = (0, scalar @$times);
    while ($lo < $hi) {
        my $mid = int(($lo + $hi) / 2);
        if (($times->[$mid] // '') lt $target) {
            $lo = $mid + 1;
        }
        else {
            $hi = $mid;
        }
    }
    return $lo;
}

sub _upper_bound_time {
    my ($times, $target) = @_;
    my ($lo, $hi) = (0, scalar @$times);
    while ($lo < $hi) {
        my $mid = int(($lo + $hi) / 2);
        if (($times->[$mid] // '') le $target) {
            $lo = $mid + 1;
        }
        else {
            $hi = $mid;
        }
    }
    return $lo;
}

sub _containing_candle {
    my ($source, $time) = @_;
    my $last;
    for my $c (@$source) {
        my $t = $c->{time};
        next unless defined $t;
        last if $t gt $time;
        $last = $c;
    }
    return $last;
}

sub _avg_volume_near {
    my ($source, $time, $win) = @_;
    return 0 unless $source && @$source;
    my $pos = 0;
    for my $i (0 .. $#$source) {
        last if ($source->[$i]{time} // '') gt $time;
        $pos = $i;
    }
    my $from = $pos >= ($win - 1) ? $pos - $win + 1 : 0;
    my ($sum, $cnt) = (0, 0);
    for my $i ($from .. $pos) {
        $sum += $source->[$i]{volume} // 0;
        $cnt++;
    }
    return $cnt ? $sum / $cnt : 0;
}

sub _tf_minutes {
    my ($tf) = @_;
    return 1     if $tf eq '1m';
    return 5     if $tf eq '5m';
    return 15    if $tf eq '15m';
    return 60    if $tf eq '1h';
    return 120   if $tf eq '2h';
    return 240   if $tf eq '4h';
    return 1440  if $tf eq 'D';
    return 10080 if $tf eq 'W';
    return 1;
}

sub _add_minutes_iso {
    my ($iso, $minutes) = @_;
    return $iso unless defined $iso && $iso =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/;
    my ($Y, $Mo, $D, $h, $mi) = ($1+0, $2+0, $3+0, $4+0, $5+0);
    require Time::Local;
    my $epoch = Time::Local::timegm(0, $mi, $h, $D, $Mo - 1, $Y - 1900);
    $epoch += ($minutes || 1) * 60;
    my @g = gmtime($epoch);
    return sprintf("%04d-%02d-%02dT%02d:%02d:00", $g[5]+1900, $g[4]+1, $g[3], $g[2], $g[1]);
}

sub _sum {
    my $s = 0;
    $s += $_ for @_;
    return $s;
}

# Determina si un precio pertenece a liquidez interna o externa
# ext_levels: arrayref de { price, type } de TFs superiores
sub _scope {
    my ($price, $ext_levels) = @_;
    return 'internal' unless $ext_levels && @$ext_levels;
    for my $el (@$ext_levels) {
        return 'external' if abs($price - $el->{price}) < ($el->{tolerance} // 0.001);
    }
    return 'internal';
}

# Detecta swing points incrementalmente (modo update_last)
sub _detect_swing_points {
    my ($self, $market, $idx, $atr, $max_visible_index, $timeframe) = @_;
    my $k = SWING_K;
    return if $idx < $k || $idx + $k > $max_visible_index;

    my $pivot_idx = $idx - $k;
    my $c = $market->get_candle($pivot_idx);

    my $is_sh = 1;
    for my $j (1..$k) {
        my $prev = $market->get_candle($pivot_idx - $j);
        my $next = $market->get_candle($pivot_idx + $j);
        if ($prev->{high} >= $c->{high} || $next->{high} >= $c->{high}) {
            $is_sh = 0; last;
        }
    }
    if ($is_sh) {
        push @{ $self->{_swings} }, {
            kind         => 'high',
            index        => $pivot_idx,
            price        => $c->{high},
            time         => $c->{time},
            confirmed_at => $idx,
            confirmed_time => $market->get_candle($idx)->{time},
        };
        push @{ $self->{levels} }, {
            id                   => _new_id(),
            type                 => 'BSL',
            origin               => 'swing',
            timeframe            => $timeframe,
            price                => $c->{high},
            start_index          => $idx,
            start_time           => $market->get_candle($idx)->{time},
            pivot_time           => $c->{time},
            end_index            => undef,
            end_time             => undef,
            tolerance            => ($atr // 0) * EQ_FACTOR,
            state                => 'DETECTED',
            active               => 1,
            internal_or_external => 'internal',
            volume_weights       => { estimated => \1 },
            _sweep_index         => undef,
            _consecutive_out     => 0,
            _sweep_candidate     => undef,
        };
    }

    my $is_sl = 1;
    for my $j (1..$k) {
        my $prev = $market->get_candle($pivot_idx - $j);
        my $next = $market->get_candle($pivot_idx + $j);
        if ($prev->{low} <= $c->{low} || $next->{low} <= $c->{low}) {
            $is_sl = 0; last;
        }
    }
    if ($is_sl) {
        push @{ $self->{_swings} }, {
            kind         => 'low',
            index        => $pivot_idx,
            price        => $c->{low},
            time         => $c->{time},
            confirmed_at => $idx,
            confirmed_time => $market->get_candle($idx)->{time},
        };
        push @{ $self->{levels} }, {
            id                   => _new_id(),
            type                 => 'SSL',
            origin               => 'swing',
            timeframe            => $timeframe,
            price                => $c->{low},
            start_index          => $idx,
            start_time           => $market->get_candle($idx)->{time},
            pivot_time           => $c->{time},
            end_index            => undef,
            end_time             => undef,
            tolerance            => ($atr // 0) * EQ_FACTOR,
            state                => 'DETECTED',
            active               => 1,
            internal_or_external => 'internal',
            volume_weights       => { estimated => \1 },
            _sweep_index         => undef,
            _consecutive_out     => 0,
            _sweep_candidate     => undef,
        };
    }
}

1;
