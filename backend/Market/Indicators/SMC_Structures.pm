package Market::Indicators::SMC_Structures;

use strict;
use warnings;

# ============================================================
#  Market::Indicators::SMC_Structures
#
#  Detecta estructura de mercado SMC. No dibuja; solo calcula.
#
#  Produce:
#    pivots     : Swing Highs/Lows con label HH/HL/LH/LL y scope
#    structures : eventos BOS, CHoCH y MSS (solo por cierre de cuerpo)
#    fvgs       : Fair Value Gaps con estado active/mitigated/invalidated
#    fib_sets   : Fibonacci basico anclado al ultimo swing externo
#    premium_discount_zones : premium/equilibrium/discount por rango estructural
#
#  Reglas criticas:
#    - BOS valido: close[i] cruza el nivel estructural (no mecha)
#    - Cada nivel solo genera UN evento (hash de niveles rotos)
#    - CHoCH real: invalida major high/low y cambia tendencia
#    - FVG: desequilibrio de 3 velas (gap entre vela[i-2] y vela[i])
#    - reaction_zone se almacena como 0/1 (no referencia)
#    - Ningun calculo usa velas con index > max_visible_index
# ============================================================

use constant SWING_K    => 3;
use constant FIB_RATIOS => [0, 0.236, 0.382, 0.5, 0.618, 0.786, 1];
use constant FADE_RATE  => 0.03;
use constant INIT_OP    => 0.40;
use constant HR_OP      => 0.70;
use constant MIN_OP     => 0.05;

my $NEXT_ID = 1;
sub _new_id { 'SMC_' . sprintf('%04d', $NEXT_ID++) }

sub new  { bless {}, shift }
sub reset { $NEXT_ID = 1 }
sub get_values { [] }

# ============================================================
#  Punto de entrada principal
# ============================================================

sub compute {
    my ($class_or_self, %args) = @_;

    my $candles   = $args{candles}           or die 'SMC::compute: falta candles';
    my $atr       = $args{atr_series}        // [];
    my $max_idx   = $args{max_visible_index} // $#$candles;
    my $tf        = $args{timeframe}         // '1m';
    my $liq_evts  = $args{liquidity_events}  // [];
    my $config    = $args{config}            // {};
    my $swing_k   = $config->{swingLookback} // SWING_K;

    $NEXT_ID = 1;

    my ($pivots, $major_high, $major_low) = _build_pivots($candles, $atr, $max_idx, $tf, $swing_k);
    my $structures = _build_structures($candles, $pivots, $max_idx, $tf, $liq_evts);
    _annotate_strong_weak_pivots($pivots, $structures, $max_idx);
    my $fvgs       = _build_fvgs($candles, $max_idx, $tf, $liq_evts);
    my $fib_sets   = _build_fib_sets($pivots, $structures, $max_idx, $tf);
    my $pd_zones   = _build_premium_discount($pivots, $structures, $fib_sets, $max_idx, $tf);

    return {
        pivots                 => $pivots,
        structures             => $structures,
        fvgs                   => $fvgs,
        fib_sets               => $fib_sets,
        premium_discount_zones => $pd_zones,
        events                 => [ @$structures, @$fvgs, @$pd_zones ],
    };
}

# ============================================================
#  Pivots: deteccion, etiquetas HH/HL/LH/LL, scope
# ============================================================

sub _build_pivots {
    my ($candles, $atr_series, $max_idx, $tf, $swing_k) = @_;
    my $k = $swing_k || SWING_K;
    my @raw;

    for my $i ($k .. $max_idx) {
        last if $i + $k > $max_idx;
        my $c = $candles->[$i];

        my $sh = 1;
        for my $j (1..$k) {
            if ($candles->[$i-$j]{high} >= $c->{high}
             || $candles->[$i+$j]{high} >= $c->{high}) { $sh=0; last }
        }
        push @raw, { kind=>'high', index=>$i, confirmed_at=>$i+$k,
                     confirmed_time=>$candles->[$i+$k]{time},
                     price=>$c->{high}, time=>$c->{time},
                     atr=>$atr_series->[$i] } if $sh;

        my $sl = 1;
        for my $j (1..$k) {
            if ($candles->[$i-$j]{low} <= $c->{low}
             || $candles->[$i+$j]{low} <= $c->{low}) { $sl=0; last }
        }
        push @raw, { kind=>'low', index=>$i, confirmed_at=>$i+$k,
                     confirmed_time=>$candles->[$i+$k]{time},
                     price=>$c->{low}, time=>$c->{time},
                     atr=>$atr_series->[$i] } if $sl;
    }

    @raw = sort { $a->{index} <=> $b->{index} } @raw;

    my @highs = grep { $_->{kind} eq 'high' } @raw;
    my @lows  = grep { $_->{kind} eq 'low'  } @raw;

    _label_sequence(\@highs, 'high');
    _label_sequence(\@lows,  'low');

    my @major_highs = grep { ($_->{rank}//'minor') eq 'major' } @highs;
    my @major_lows  = grep { ($_->{rank}//'minor') eq 'major' } @lows;

    my $major_high = @major_highs ? $major_highs[-1] : $highs[-1];
    my $major_low  = @major_lows  ? $major_lows[-1]  : $lows[-1];

    for my $p (@raw) {
        $p->{id}        = _new_id();
        $p->{timeframe} = $tf;
        $p->{scope}     = (($p->{rank}//'minor') eq 'major') ? 'external' : 'internal';
    }

    return (\@raw, $major_high, $major_low);
}

sub _annotate_strong_weak_pivots {
    my ($pivots, $structures, $max_idx) = @_;
    return unless $pivots && @$pivots;

    my %broken_by_pivot;
    for my $st (@{ $structures // [] }) {
        next unless defined $st->{pivot_id};
        next if ($st->{confirmation_index} // $st->{break_index} // 9_999_999) > $max_idx;
        $broken_by_pivot{ $st->{pivot_id} } = $st;
    }

    my $last_external_direction = 'unknown';
    for my $st (@{ $structures // [] }) {
        next unless ($st->{scope} // '') eq 'external';
        next if ($st->{confirmation_index} // $st->{break_index} // 9_999_999) > $max_idx;
        $last_external_direction = $st->{direction} // $last_external_direction;
    }

    for my $p (@$pivots) {
        next unless defined $p->{id};
        if (my $break = $broken_by_pivot{ $p->{id} }) {
            $p->{strength_class} = ($p->{kind} // '') eq 'high' ? 'weak_high' : 'weak_low';
            $p->{strength_status} = 'broken';
            $p->{broken_by_event_id} = $break->{id};
            $p->{broken_time} = $break->{break_time};
        }
        elsif (($p->{kind} // '') eq 'high') {
            $p->{strength_class} = $last_external_direction eq 'bearish' ? 'strong_high' : 'weak_high';
            $p->{strength_status} = 'active';
        }
        else {
            $p->{strength_class} = $last_external_direction eq 'bullish' ? 'strong_low' : 'weak_low';
            $p->{strength_status} = 'active';
        }
    }
}

sub _label_sequence {
    my ($pts, $kind) = @_;
    return unless @$pts;
    $pts->[0]{label} = ($kind eq 'high') ? 'HH' : 'LL';
    $pts->[0]{rank}  = 'major';
    return if @$pts == 1;

    for my $i (1 .. $#$pts) {
        my $prev = $pts->[$i-1];
        my $cur  = $pts->[$i];
        if ($kind eq 'high') {
            if ($cur->{price} > $prev->{price}) {
                $cur->{label} = 'HH'; $cur->{rank} = 'major';
            } else {
                $cur->{label} = 'LH'; $cur->{rank} = 'minor';
            }
        } else {
            if ($cur->{price} < $prev->{price}) {
                $cur->{label} = 'LL'; $cur->{rank} = 'major';
            } else {
                $cur->{label} = 'HL'; $cur->{rank} = 'minor';
            }
        }
    }
}

# ============================================================
#  BOS y CHoCH
#  Regla: cada nivel estructural solo genera UN evento.
#         Se usa %broken para evitar la cascada.
# ============================================================

sub _build_structures {
    my ($candles, $pivots, $max_idx, $tf, $liq_evts) = @_;

    my @confirmed = sort {
        ($a->{confirmed_at} // 0) <=> ($b->{confirmed_at} // 0)
            || ($a->{index} // 0) <=> ($b->{index} // 0)
    } grep { defined $_->{rank} } @$pivots;

    return [] unless @confirmed;

    my %broken;  # scope|kind|pivot_id => 1 (nivel ya roto, no repetir)
    my %ctx = (
        external => { trend => 'unknown', high => undef, low => undef },
        internal => { trend => 'unknown', high => undef, low => undef },
    );
    my @out;
    my $ptr = 0;

    for my $i (1 .. $max_idx) {
        last if $i > $#$candles;
        my $c = $candles->[$i];

        # Actualizar pivots confirmados hasta i. Los major alimentan estructura
        # externa; los minor alimentan estructura interna.
        while ($ptr <= $#confirmed && $confirmed[$ptr]{confirmed_at} <= $i) {
            my $p = $confirmed[$ptr];
            my $scope = (($p->{rank} // 'minor') eq 'major') ? 'external' : 'internal';
            $ctx{$scope}{ $p->{kind} } = $p;
            $ptr++;
        }

        for my $scope (qw(external internal)) {
            my $hi = $ctx{$scope}{high};
            if ($hi && $c->{close} > $hi->{price}) {
                my $key = join('|', $scope, 'high', $hi->{id});
                if (!$broken{$key}) {
                    $broken{$key} = 1;
                    my $old_trend = $ctx{$scope}{trend};
                    my $type = ($old_trend eq 'bearish') ? 'CHOCH' : 'BOS';
                    my $ev = _structure_event(
                        $type, 'bullish', $tf, $hi, $i, $c, $scope, $liq_evts, $old_trend,
                    );
                    push @out, $ev;
                    push @out, _mss_event_from_choch($ev, $old_trend)
                        if $type eq 'CHOCH';
                    $ctx{$scope}{trend} = 'bullish';
                }
            }

            my $lo = $ctx{$scope}{low};
            if ($lo && $c->{close} < $lo->{price}) {
                my $key = join('|', $scope, 'low', $lo->{id});
                if (!$broken{$key}) {
                    $broken{$key} = 1;
                    my $old_trend = $ctx{$scope}{trend};
                    my $type = ($old_trend eq 'bullish') ? 'CHOCH' : 'BOS';
                    my $ev = _structure_event(
                        $type, 'bearish', $tf, $lo, $i, $c, $scope, $liq_evts, $old_trend,
                    );
                    push @out, $ev;
                    push @out, _mss_event_from_choch($ev, $old_trend)
                        if $type eq 'CHOCH';
                    $ctx{$scope}{trend} = 'bearish';
                }
            }
        }
    }

    return \@out;
}

sub _structure_event {
    my ($type, $direction, $tf, $pivot, $i, $c, $scope, $liq_evts, $previous_trend) = @_;
    my $quality = _quality($c, $liq_evts, $i);
    return {
        id             => _new_id(),
        type           => $type,
        direction      => $direction,
        timeframe      => $tf,
        pivot_id       => $pivot->{id},
        pivot_time     => $pivot->{time},
        pivot_confirmed_at   => $pivot->{confirmed_at},
        pivot_confirmation_time => $pivot->{confirmed_time},
        break_index    => $i,
        break_time     => $c->{time},
        break_price    => $pivot->{price},
        close_price    => $c->{close},
        confirmation_index => $i,
        confirmation_time  => $c->{time},
        start_time     => $c->{time},
        price          => $pivot->{price},
        status         => 'confirmed',
        confirmed      => 1,
        break_mode     => 'close',
        scope          => $scope,
        previous_trend => $previous_trend // 'unknown',
        real_or_false  => $scope eq 'external' || $quality >= 0.65 ? 'real' : 'internal',
        quality_score  => $quality,
        liquidity_context => _near_liq($liq_evts, $i),
    };
}

sub _mss_event_from_choch {
    my ($choch, $previous_trend) = @_;
    return {
        %$choch,
        id                 => _new_id(),
        type               => 'MSS',
        source_choch_id    => $choch->{id},
        previous_trend     => $previous_trend // $choch->{previous_trend} // 'unknown',
        quality_score      => (($choch->{quality_score} // 0.5) + 0.05 > 1)
                              ? 1 : (($choch->{quality_score} // 0.5) + 0.05),
        real_or_false      => ($choch->{scope} // '') eq 'external' ? 'real' : 'internal',
        liquidity_context  => $choch->{liquidity_context},
        status             => 'confirmed',
    };
}

sub _quality {
    my ($c, $liq_evts, $idx) = @_;
    my $body  = abs($c->{close} - $c->{open});
    my $range = $c->{high} - $c->{low};
    my $score = 0.5;
    $score += 0.2 if $range > 0 && ($body / $range) > 0.6;
    $score += 0.15 if _near_liq($liq_evts, $idx);
    return $score > 1 ? 1 : $score;
}

sub _near_liq {
    my ($liq_evts, $idx) = @_;
    return undef unless $liq_evts && @$liq_evts;
    my @near = grep {
        defined $_->{resolved_index} && abs($_->{resolved_index} - $idx) <= 5
    } @$liq_evts;
    return @near ? $near[-1]{id} : undef;
}

# ============================================================
#  FVG: Fair Value Gaps
#  reaction_zone se guarda como 0 o 1 (entero), no referencia,
#  para poder filtrarlo correctamente en Perl.
# ============================================================

sub _build_fvgs {
    my ($candles, $max_idx, $tf, $liq_evts) = @_;

    # Indice de swept_index de cada evento de liquidez
    my %liq_at;
    for my $ev (@{ $liq_evts // [] }) {
        my $si = $ev->{swept_index};
        next unless defined $si;
        $liq_at{$si} = $ev;
    }

    my @fvgs;

    for my $i (2 .. $max_idx) {
        last if $i > $#$candles;
        my $c0 = $candles->[$i-2];
        my $c2 = $candles->[$i];

        # Bullish FVG: low[i] > high[i-2]
        if ($c2->{low} > $c0->{high}) {
            my $hr  = (exists $liq_at{$i-1} || exists $liq_at{$i-2}) ? 1 : 0;
            my $lev = $hr ? ($liq_at{$i-1} // $liq_at{$i-2}) : undef;
            push @fvgs, {
                id                        => _new_id(),
                timeframe                 => $tf,
                direction                 => 'bullish',
                start_index               => $i-2,
                middle_index              => $i-1,
                end_index                 => $i,
                start_time                => $c0->{time},
                middle_time               => $candles->[$i-1]{time},
                end_time                  => $c2->{time},
                gap_low                   => $c0->{high},
                gap_high                  => $c2->{low},
                status                    => 'active',
                reaction_zone             => $hr,
                source_liquidity_event_id => $lev ? $lev->{id} : undef,
                opacity                   => $hr ? HR_OP : INIT_OP,
                fade_start_index          => $i,
                fade_rate                 => FADE_RATE,
                formed_index              => $i,
                confirmation_index        => $i,
                confirmation_time         => $c2->{time},
                project_until_index       => $max_idx,
                project_until_time        => $candles->[$max_idx]{time},
            };
        }

        # Bearish FVG: high[i] < low[i-2]
        if ($c2->{high} < $c0->{low}) {
            my $hr  = (exists $liq_at{$i-1} || exists $liq_at{$i-2}) ? 1 : 0;
            my $lev = $hr ? ($liq_at{$i-1} // $liq_at{$i-2}) : undef;
            push @fvgs, {
                id                        => _new_id(),
                timeframe                 => $tf,
                direction                 => 'bearish',
                start_index               => $i-2,
                middle_index              => $i-1,
                end_index                 => $i,
                start_time                => $c0->{time},
                middle_time               => $candles->[$i-1]{time},
                end_time                  => $c2->{time},
                gap_high                  => $c0->{low},
                gap_low                   => $c2->{high},
                status                    => 'active',
                reaction_zone             => $hr,
                source_liquidity_event_id => $lev ? $lev->{id} : undef,
                opacity                   => $hr ? HR_OP : INIT_OP,
                fade_start_index          => $i,
                fade_rate                 => FADE_RATE,
                formed_index              => $i,
                confirmation_index        => $i,
                confirmation_time         => $c2->{time},
                project_until_index       => $max_idx,
                project_until_time        => $candles->[$max_idx]{time},
            };
        }
    }

    _update_fvg_states(\@fvgs, $candles, $max_idx);
    return \@fvgs;
}

sub _update_fvg_states {
    my ($fvgs, $candles, $max_idx) = @_;
    for my $fvg (@$fvgs) {
        my $start_age = $fvg->{fade_start_index};
        my $resolved;
        for my $i ($fvg->{end_index}+1 .. $max_idx) {
            last if $i > $#$candles;
            my $c = $candles->[$i];

            # Fade: opacidad decrece con la edad
            my $age = $i - $start_age;
            my $op  = $fvg->{opacity} - $age * $fvg->{fade_rate};
            $fvg->{current_opacity} = $op < MIN_OP ? MIN_OP : $op;

            if ($fvg->{direction} eq 'bullish') {
                if ($c->{close} <= $fvg->{gap_low}) {
                    $resolved = [ invalidated => $i, $c->{time} ];
                    last;
                } elsif ($c->{low} < $fvg->{gap_high}) {
                    $resolved = [ mitigated => $i, $c->{time} ];
                    last;
                }
            } else {
                if ($c->{close} >= $fvg->{gap_high}) {
                    $resolved = [ invalidated => $i, $c->{time} ];
                    last;
                } elsif ($c->{high} > $fvg->{gap_low}) {
                    $resolved = [ mitigated => $i, $c->{time} ];
                    last;
                }
            }
        }
        if ($resolved) {
            my ($status, $idx, $time) = @$resolved;
            $fvg->{status} = $status;
            $fvg->{project_until_index} = $idx;
            $fvg->{project_until_time}  = $time;
            if ($status eq 'mitigated') {
                $fvg->{mitigation_index} = $idx;
                $fvg->{mitigation_time}  = $time;
            }
            else {
                $fvg->{invalidation_index} = $idx;
                $fvg->{invalidation_time}  = $time;
            }
        }
        else {
            $fvg->{status} = 'active';
            $fvg->{project_until_index} = $max_idx;
            $fvg->{project_until_time}  = $candles->[$max_idx]{time};
        }
        $fvg->{current_opacity} //= $fvg->{opacity};
    }
}

# ============================================================
#  Fibonacci basico
# ============================================================

sub _build_fib_sets {
    my ($pivots, $structures, $max_idx, $tf) = @_;

    my @ext = grep { ($_->{scope}//'') eq 'external' } @$structures;
    return [] unless @ext;

    my @highs  = grep { $_->{kind} eq 'high' && $_->{confirmed_at} <= $max_idx } @$pivots;
    my @lows   = grep { $_->{kind} eq 'low'  && $_->{confirmed_at} <= $max_idx } @$pivots;
    return [] unless @highs && @lows;

    my %pivot_by_id = map { $_->{id} => $_ } @$pivots;
    my @sets;

    for my $st (@ext) {
        next if ($st->{break_index} // 9_999_999) > $max_idx;

        my ($a, $b);
        if (($st->{direction} // '') eq 'bullish') {
            $b = $pivot_by_id{ $st->{pivot_id} } // _last_before(\@highs, $st->{break_index});
            $a = _last_before(\@lows, defined $b ? $b->{index} : $st->{break_index});
            next unless $a && $b && $b->{price} > $a->{price};
        }
        else {
            $b = $pivot_by_id{ $st->{pivot_id} } // _last_before(\@lows, $st->{break_index});
            $a = _last_before(\@highs, defined $b ? $b->{index} : $st->{break_index});
            next unless $a && $b && $a->{price} > $b->{price};
        }

        my $high = $a->{price} > $b->{price} ? $a->{price} : $b->{price};
        my $low  = $a->{price} < $b->{price} ? $a->{price} : $b->{price};
        my $range = $high - $low;
        next if $range <= 0;

        my @levels = map {
            my $price = ($st->{direction} // '') eq 'bullish'
                ? $high - $range * $_
                : $low  + $range * $_;
            {
                ratio => $_,
                price => $price,
            }
        } @{ FIB_RATIOS() };

        push @sets, {
            id                 => _new_id(),
            timeframe          => $tf,
            anchor_start_index => $a->{index},
            anchor_end_index   => $b->{index},
            anchor_start_time  => $a->{time},
            anchor_end_time    => $b->{time},
            anchor_high        => $high,
            anchor_low         => $low,
            source_event_id    => $st->{id},
            direction          => $st->{direction},
            break_index        => $st->{break_index},
            break_time         => $st->{break_time},
            levels             => \@levels,
        };
    }

    return \@sets;
}

sub _build_premium_discount {
    my ($pivots, $structures, $fib_sets, $max_idx, $tf) = @_;
    my @out;
    my %seen;

    my @sets = @{ $fib_sets // [] };
    @sets = @sets > 8 ? @sets[-8 .. -1] : @sets;

    for my $fs (@sets) {
        my $high = $fs->{anchor_high};
        my $low  = $fs->{anchor_low};
        next unless defined $high && defined $low && $high > $low;
        my $key = join(':', $fs->{anchor_start_index}, $fs->{anchor_end_index}, $fs->{source_event_id} // '');
        next if $seen{$key}++;
        push @out, _pd_zone(
            $tf, $max_idx,
            start_index        => $fs->{anchor_start_index},
            start_time         => $fs->{anchor_start_time},
            confirmation_index => $fs->{break_index},
            confirmation_time  => $fs->{break_time},
            anchor_high        => $high,
            anchor_low         => $low,
            direction          => $fs->{direction},
            source_event_id    => $fs->{source_event_id},
            source_fib_id      => $fs->{id},
            source             => 'fibonacci_auto',
        );
    }

    # Fallback dinamico: Premium/Discount debe existir aunque no haya fib_set
    # en la ventana. Usa el ultimo rango estructural confirmado disponible.
    my @confirmed = grep { ($_->{confirmed_at} // 9_999_999) <= $max_idx } @{ $pivots // [] };
    my @highs = grep { $_->{kind} eq 'high' } @confirmed;
    my @lows  = grep { $_->{kind} eq 'low'  } @confirmed;
    if (@highs && @lows) {
        my $h = $highs[-1];
        my $l = $lows[-1];
        my ($a, $b) = ($h->{index} <= $l->{index}) ? ($h, $l) : ($l, $h);
        my $direction = $a->{kind} eq 'low' && $b->{kind} eq 'high' ? 'bullish' : 'bearish';
        my $key = join(':', $a->{index}, $b->{index}, 'current_range');
        if (!$seen{$key}++) {
            push @out, _pd_zone(
                $tf, $max_idx,
                start_index        => $a->{index},
                start_time         => $a->{time},
                confirmation_index => $b->{confirmed_at},
                confirmation_time  => $b->{confirmed_time},
                anchor_high        => $h->{price},
                anchor_low         => $l->{price},
                direction          => $direction,
                source_event_id    => undef,
                source_fib_id      => undef,
                source             => 'current_structure_range',
            );
        }
    }

    return \@out;
}

sub _pd_zone {
    my ($tf, $max_idx, %args) = @_;
    my $high = $args{anchor_high};
    my $low  = $args{anchor_low};
    return () unless defined $high && defined $low && $high > $low;
    my $eq = $low + (($high - $low) * 0.5);

    return {
        id                 => _new_id(),
        type               => 'premium_discount',
        timeframe          => $tf,
        source_event_id    => $args{source_event_id},
        source_fib_id      => $args{source_fib_id},
        source             => $args{source},
        direction          => $args{direction},
        start_index        => $args{start_index},
        start_time         => $args{start_time},
        confirmation_index => $args{confirmation_index},
        confirmation_time  => $args{confirmation_time},
        end_index          => $max_idx,
        project_until_index=> $max_idx,
        anchor_high        => $high,
        anchor_low         => $low,
        equilibrium_price  => $eq,
        premium_top        => $high,
        premium_bottom     => $eq,
        discount_top       => $eq,
        discount_bottom    => $low,
        status             => 'active',
    };
}

sub _last_before {
    my ($arr, $idx) = @_;
    my $last;
    for my $p (@$arr) {
        last if ($p->{index} // 9_999_999) > $idx;
        $last = $p;
    }
    return $last;
}

1;
