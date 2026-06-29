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
#    structures : eventos BOS y CHoCH (solo por cierre de cuerpo)
#    fvgs       : Fair Value Gaps con fade temporal
#    fib_sets   : Fibonacci basico anclado al ultimo swing externo
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

    $NEXT_ID = 1;

    my ($pivots, $major_high, $major_low) = _build_pivots($candles, $atr, $max_idx, $tf);
    my $structures = _build_structures($candles, $pivots, $max_idx, $tf, $liq_evts);
    my $fvgs       = _build_fvgs($candles, $max_idx, $tf, $liq_evts);
    my $fib_sets   = _build_fib_sets($pivots, $structures, $max_idx, $tf);

    return {
        pivots     => $pivots,
        structures => $structures,
        fvgs       => $fvgs,
        fib_sets   => $fib_sets,
    };
}

# ============================================================
#  Pivots: deteccion, etiquetas HH/HL/LH/LL, scope
# ============================================================

sub _build_pivots {
    my ($candles, $atr_series, $max_idx, $tf) = @_;
    my $k = SWING_K;
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
                     price=>$c->{high}, time=>$c->{time},
                     atr=>$atr_series->[$i] } if $sh;

        my $sl = 1;
        for my $j (1..$k) {
            if ($candles->[$i-$j]{low} <= $c->{low}
             || $candles->[$i+$j]{low} <= $c->{low}) { $sl=0; last }
        }
        push @raw, { kind=>'low', index=>$i, confirmed_at=>$i+$k,
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

sub _label_sequence {
    my ($pts, $kind) = @_;
    return unless @$pts >= 2;
    $pts->[0]{label} = ($kind eq 'high') ? 'HH' : 'LL';
    $pts->[0]{rank}  = 'major';

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
                    my $type = ($ctx{$scope}{trend} eq 'bearish') ? 'CHOCH' : 'BOS';
                    push @out, _structure_event(
                        $type, 'bullish', $tf, $hi, $i, $c, $scope, $liq_evts,
                    );
                    $ctx{$scope}{trend} = 'bullish';
                }
            }

            my $lo = $ctx{$scope}{low};
            if ($lo && $c->{close} < $lo->{price}) {
                my $key = join('|', $scope, 'low', $lo->{id});
                if (!$broken{$key}) {
                    $broken{$key} = 1;
                    my $type = ($ctx{$scope}{trend} eq 'bullish') ? 'CHOCH' : 'BOS';
                    push @out, _structure_event(
                        $type, 'bearish', $tf, $lo, $i, $c, $scope, $liq_evts,
                    );
                    $ctx{$scope}{trend} = 'bearish';
                }
            }
        }
    }

    return \@out;
}

sub _structure_event {
    my ($type, $direction, $tf, $pivot, $i, $c, $scope, $liq_evts) = @_;
    my $quality = _quality($c, $liq_evts, $i);
    return {
        id             => _new_id(),
        type           => $type,
        direction      => $direction,
        timeframe      => $tf,
        pivot_id       => $pivot->{id},
        break_index    => $i,
        break_time     => $c->{time},
        break_price    => $pivot->{price},
        close_price    => $c->{close},
        confirmed      => 1,
        break_mode     => 'close',
        scope          => $scope,
        real_or_false  => $scope eq 'external' || $quality >= 0.65 ? 'real' : 'internal',
        quality_score  => $quality,
        liquidity_context => _near_liq($liq_evts, $i),
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
                status                    => 'open',
                reaction_zone             => $hr,
                source_liquidity_event_id => $lev ? $lev->{id} : undef,
                opacity                   => $hr ? HR_OP : INIT_OP,
                fade_start_index          => $i,
                fade_rate                 => FADE_RATE,
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
                status                    => 'open',
                reaction_zone             => $hr,
                source_liquidity_event_id => $lev ? $lev->{id} : undef,
                opacity                   => $hr ? HR_OP : INIT_OP,
                fade_start_index          => $i,
                fade_rate                 => FADE_RATE,
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
        for my $i ($fvg->{end_index}+1 .. $max_idx) {
            last if $i > $#$candles;
            my $c = $candles->[$i];

            # Fade: opacidad decrece con la edad
            my $age = $i - $start_age;
            my $op  = $fvg->{opacity} - $age * $fvg->{fade_rate};
            $fvg->{current_opacity} = $op < MIN_OP ? MIN_OP : $op;

            if ($fvg->{direction} eq 'bullish') {
                if ($c->{low} <= $fvg->{gap_low}) {
                    $fvg->{status} = 'filled'; last;
                } elsif ($c->{low} < $fvg->{gap_high}) {
                    $fvg->{status} = 'partially_filled';
                }
            } else {
                if ($c->{high} >= $fvg->{gap_high}) {
                    $fvg->{status} = 'filled'; last;
                } elsif ($c->{high} > $fvg->{gap_low}) {
                    $fvg->{status} = 'partially_filled';
                }
            }
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
