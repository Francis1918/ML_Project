package Market::Indicators::Strategy_Builder;

use strict;
use warnings;
use List::Util qw(max min sum);

# ============================================================
#  Market::Indicators::Strategy_Builder
#
#  Motor analitico para estrategias y contexto operativo.
#  No dibuja; entrega estructuras listas para Market::Overlays.
#
#  Implementa:
#    - SuperTrend con ATR y multiplicador configurable.
#    - HalfTrend aproximado con filtro de reversión por ATR.
#    - Range Filter con rango suavizado.
#    - Supply/Demand validados por desplazamiento y volumen.
#    - Order Blocks asociados al desplazamiento que confirma la zona.
#    - Support/Resistance por clusters de pivots.
#    - Trendlines y canales a partir de swings confirmados.
#    - Niveles de cuerpo/mecha de la vela diaria cerrada previa.
#
#  Regla Replay:
#    Ningun calculo usa velas con index > max_visible_index.
# ============================================================

use constant ST_MULT          => 3.0;
use constant HT_AMP           => 6;
use constant HT_ATR_MULT      => 1.4;
use constant RF_PERIOD        => 14;
use constant RF_MULT          => 2.5;
use constant VOL_WIN          => 20;
use constant ZONE_LOOKBACK    => 8;
use constant ZONE_MIN_VOL     => 1.15;
use constant ZONE_MIN_BODY    => 0.55;
use constant ZONE_ATR_FACTOR  => 1.05;
use constant SR_MAX_PIVOTS    => 180;
use constant SR_MIN_TOUCHES   => 2;
use constant TL_MAX_LINES     => 28;

my $NEXT_ID = 1;
sub _new_id { return 'STG_' . sprintf('%04d', $NEXT_ID++) }

sub new  { bless {}, shift }
sub reset { $NEXT_ID = 1 }
sub get_values { [] }

sub compute {
    my ($class_or_self, %args) = @_;

    my $candles    = $args{candles}           or die 'Strategy_Builder::compute: falta candles';
    my $atr_series = $args{atr_series}        // [];
    my $max_idx    = $args{max_visible_index} // $#$candles;
    my $tf         = $args{timeframe}         // '1m';
    my $liq_lvls   = $args{liquidity_levels}  // [];
    my $liq_evts   = $args{liquidity_events}  // [];
    my $structs    = $args{structure_events}  // [];
    my $pivots     = $args{pivots}            // [];
    my $daily      = $args{daily_candles}     // [];

    $NEXT_ID = 1;
    $max_idx = $#$candles if $max_idx > $#$candles;
    return _empty_result() if $max_idx < 1;

    my $vol_avg = _volume_average($candles, $max_idx);

    my $supertrend   = _build_supertrend($candles, $atr_series, $max_idx, $tf);
    my $halftrend    = _build_halftrend($candles, $atr_series, $max_idx, $tf);
    my $range_filter = _build_range_filter($candles, $max_idx, $tf);
    my ($supply, $demand, $order_blocks) =
        _build_zones($candles, $atr_series, $vol_avg, $liq_evts, $structs, $max_idx, $tf);
    my $support_resistance =
        _build_support_resistance($pivots, $candles, $atr_series, $max_idx, $tf);
    my ($trendlines, $channels) =
        _build_trendlines_and_channels($pivots, $candles, $max_idx, $tf);
    my $daily_levels =
        _build_daily_levels($candles, $daily, $atr_series, $max_idx, $tf);

    return {
        supertrend          => $supertrend,
        halftrend           => $halftrend,
        range_filter        => $range_filter,
        supply_zones        => $supply,
        demand_zones        => $demand,
        order_blocks        => $order_blocks,
        support_resistance  => $support_resistance,
        trendlines          => $trendlines,
        channels            => $channels,
        daily_levels        => $daily_levels,
        liquidity_links     => _strategy_liquidity_links($liq_lvls, $liq_evts, $max_idx),
    };
}

sub _empty_result {
    return {
        supertrend         => [],
        halftrend          => [],
        range_filter       => [],
        supply_zones       => [],
        demand_zones       => [],
        order_blocks       => [],
        support_resistance => [],
        trendlines         => [],
        channels           => [],
        daily_levels       => [],
        liquidity_links    => [],
    };
}

sub _build_supertrend {
    my ($candles, $atr_series, $max_idx, $tf) = @_;
    my @out;
    my ($final_upper, $final_lower, $dir);

    for my $i (0 .. $max_idx) {
        my $c = $candles->[$i];
        my $atr = _atr_at($atr_series, $candles, $i);
        my $hl2 = ($c->{high} + $c->{low}) / 2;
        my $basic_upper = $hl2 + ST_MULT * $atr;
        my $basic_lower = $hl2 - ST_MULT * $atr;

        if ($i == 0) {
            $final_upper = $basic_upper;
            $final_lower = $basic_lower;
            $dir = 'bullish';
        }
        else {
            my $prev_close = $candles->[$i - 1]{close};
            $final_upper = ($basic_upper < $final_upper || $prev_close > $final_upper)
                ? $basic_upper : $final_upper;
            $final_lower = ($basic_lower > $final_lower || $prev_close < $final_lower)
                ? $basic_lower : $final_lower;

            if ($dir eq 'bearish' && $c->{close} > $final_upper) {
                $dir = 'bullish';
            }
            elsif ($dir eq 'bullish' && $c->{close} < $final_lower) {
                $dir = 'bearish';
            }
        }

        push @out, {
            id         => _new_id(),
            index      => $i,
            time       => $c->{time},
            timeframe  => $tf,
            direction  => $dir,
            value      => $dir eq 'bullish' ? $final_lower : $final_upper,
            upper_band => $final_upper,
            lower_band => $final_lower,
            atr        => $atr,
        };
    }

    return \@out;
}

sub _build_halftrend {
    my ($candles, $atr_series, $max_idx, $tf) = @_;
    my @out;
    my $dir = $candles->[1]{close} >= $candles->[0]{close} ? 'bullish' : 'bearish';
    my $trend_value = $candles->[0]{close};

    for my $i (0 .. $max_idx) {
        my $from = $i - HT_AMP + 1;
        $from = 0 if $from < 0;
        my ($hi, $lo) = _high_low($candles, $from, $i);
        my $atr = _atr_at($atr_series, $candles, $i);
        my $dev = $atr * HT_ATR_MULT;
        my $close = $candles->[$i]{close};

        if ($dir eq 'bullish') {
            $trend_value = max($trend_value, $lo);
            if ($close < $trend_value - $dev) {
                $dir = 'bearish';
                $trend_value = $hi;
            }
        }
        else {
            $trend_value = min($trend_value, $hi);
            if ($close > $trend_value + $dev) {
                $dir = 'bullish';
                $trend_value = $lo;
            }
        }

        push @out, {
            id        => _new_id(),
            index     => $i,
            time      => $candles->[$i]{time},
            timeframe => $tf,
            direction => $dir,
            value     => $trend_value,
            high_ref  => $hi,
            low_ref   => $lo,
            atr       => $atr,
        };
    }

    return \@out;
}

sub _build_range_filter {
    my ($candles, $max_idx, $tf) = @_;
    my @out;
    my $alpha = 2 / (RF_PERIOD + 1);
    my $smooth_range = 0;
    my $filter = $candles->[0]{close};
    my $dir = 'neutral';

    for my $i (0 .. $max_idx) {
        my $close = $candles->[$i]{close};
        my $prev_close = $i > 0 ? $candles->[$i - 1]{close} : $close;
        my $abs_move = abs($close - $prev_close);
        $smooth_range = $i == 0 ? $abs_move : ($smooth_range + $alpha * ($abs_move - $smooth_range));
        my $range = $smooth_range * RF_MULT;

        if ($close > $filter + $range) {
            $filter = $close - $range;
            $dir = 'bullish';
        }
        elsif ($close < $filter - $range) {
            $filter = $close + $range;
            $dir = 'bearish';
        }

        push @out, {
            id        => _new_id(),
            index     => $i,
            time      => $candles->[$i]{time},
            timeframe => $tf,
            direction => $dir,
            value     => $filter,
            range     => $range,
        };
    }

    return \@out;
}

sub _build_zones {
    my ($candles, $atr_series, $vol_avg, $liq_evts, $structs, $max_idx, $tf) = @_;
    my (@supply, @demand, @obs);

    for my $i (1 .. $max_idx) {
        my $c = $candles->[$i];
        my $range = $c->{high} - $c->{low};
        next unless $range > 0;
        my $body = abs($c->{close} - $c->{open});
        my $atr = _atr_at($atr_series, $candles, $i);
        my $vol_ratio = ($vol_avg->[$i] || 1) > 0 ? ($c->{volume} // 0) / ($vol_avg->[$i] || 1) : 0;

        next unless $body / $range >= ZONE_MIN_BODY;
        next unless $range >= $atr * ZONE_ATR_FACTOR;
        next unless $vol_ratio >= ZONE_MIN_VOL;

        my $bullish_impulse = $c->{close} > $c->{open};
        my $j = _last_opposite_candle($candles, $i - 1, $bullish_impulse);
        next unless defined $j;

        my $base = $candles->[$j];
        my $zone_type = $bullish_impulse ? 'demand' : 'supply';
        my ($low, $high) = _zone_bounds($base, $zone_type);
        my $resolved = _resolve_zone($candles, $i + 1, $max_idx, $zone_type, $low, $high);
        my $liq_link = _near_event($liq_evts, $i, 6);
        my $struct_link = _near_structure($structs, $i, 4);

        my $zone = {
            id                    => _new_id(),
            type                  => $zone_type,
            timeframe             => $tf,
            start_index           => $j,
            start_time            => $base->{time},
            confirmed_index       => $i,
            confirmed_time        => $c->{time},
            end_index             => $resolved->{end_index},
            end_time              => $resolved->{end_time},
            low                   => $low,
            high                  => $high,
            active                => $resolved->{active},
            status                => $resolved->{status},
            displacement_index    => $i,
            displacement_time     => $c->{time},
            displacement_range    => $range,
            volume_ratio          => sprintf('%.3f', $vol_ratio) + 0,
            liquidity_context_id  => $liq_link ? $liq_link->{id} : undef,
            structure_context_id  => $struct_link ? $struct_link->{id} : undef,
        };

        if ($zone_type eq 'demand') { push @demand, $zone }
        else                        { push @supply, $zone }

        push @obs, {
            %$zone,
            id      => _new_id(),
            type    => $bullish_impulse ? 'bullish_ob' : 'bearish_ob',
            ob_side => $bullish_impulse ? 'bullish' : 'bearish',
        };
    }

    return (\@supply, \@demand, \@obs);
}

sub _build_support_resistance {
    my ($pivots, $candles, $atr_series, $max_idx, $tf) = @_;
    return [] unless $pivots && @$pivots;

    my @pts = grep { ($_->{confirmed_at} // 9_999_999) <= $max_idx } @$pivots;
    @pts = @pts > SR_MAX_PIVOTS ? @pts[-SR_MAX_PIVOTS .. -1] : @pts;
    my @clusters;

    for my $p (@pts) {
        my $atr = _atr_at($atr_series, $candles, $p->{index});
        my $tol = $atr > 0 ? $atr * 0.25 : abs($p->{price}) * 0.0008;
        $tol = 0.001 if $tol <= 0;

        my $best;
        for my $cl (@clusters) {
            next unless $cl->{kind} eq $p->{kind};
            next if abs($cl->{price} - $p->{price}) > max($tol, $cl->{tolerance});
            $best = $cl;
            last;
        }

        if ($best) {
            my $touches = $best->{touches} + 1;
            $best->{price} = (($best->{price} * $best->{touches}) + $p->{price}) / $touches;
            $best->{touches} = $touches;
            $best->{last_index} = $p->{index};
            $best->{last_time} = $p->{time};
            push @{ $best->{pivot_ids} }, $p->{id};
        }
        else {
            push @clusters, {
                id          => _new_id(),
                kind        => $p->{kind},
                type        => $p->{kind} eq 'high' ? 'resistance' : 'support',
                timeframe   => $tf,
                price       => $p->{price},
                tolerance   => $tol,
                touches     => 1,
                first_index => $p->{index},
                first_time  => $p->{time},
                last_index  => $p->{index},
                last_time   => $p->{time},
                pivot_ids   => [$p->{id}],
            };
        }
    }

    my @out;
    for my $cl (@clusters) {
        next unless $cl->{touches} >= SR_MIN_TOUCHES || ($cl->{last_index} // 0) > $max_idx - 80;
        my $broken = _sr_broken($candles, $cl, $max_idx);
        push @out, {
            %$cl,
            active    => $broken ? 0 : 1,
            end_index => $broken ? $broken->{index} : undef,
            end_time  => $broken ? $broken->{time}  : undef,
        };
    }

    return \@out;
}

sub _build_trendlines_and_channels {
    my ($pivots, $candles, $max_idx, $tf) = @_;
    return ([], []) unless $pivots && @$pivots;

    my @highs = grep { $_->{kind} eq 'high' && ($_->{confirmed_at} // 9_999_999) <= $max_idx } @$pivots;
    my @lows  = grep { $_->{kind} eq 'low'  && ($_->{confirmed_at} // 9_999_999) <= $max_idx } @$pivots;
    my (@lines, @channels);

    _append_trendlines(\@lines, \@channels, \@highs, \@lows,  $candles, $max_idx, $tf, 'resistance');
    _append_trendlines(\@lines, \@channels, \@lows,  \@highs, $candles, $max_idx, $tf, 'support');

    @lines = @lines > TL_MAX_LINES ? @lines[-TL_MAX_LINES .. -1] : @lines;
    @channels = @channels > TL_MAX_LINES ? @channels[-TL_MAX_LINES .. -1] : @channels;
    return (\@lines, \@channels);
}

sub _append_trendlines {
    my ($lines, $channels, $pts, $opposite_pts, $candles, $max_idx, $tf, $line_type) = @_;
    return unless $pts && @$pts >= 2;

    for my $i (1 .. $#$pts) {
        my $a = $pts->[$i - 1];
        my $b = $pts->[$i];
        next if $b->{index} <= $a->{index};

        my $slope = ($b->{price} - $a->{price}) / ($b->{index} - $a->{index});
        my $y2 = $a->{price} + $slope * ($max_idx - $a->{index});
        my $dir = $slope >= 0 ? 'bullish' : 'bearish';

        my $line = {
            id          => _new_id(),
            type        => $line_type,
            timeframe   => $tf,
            start_index => $a->{index},
            start_time  => $a->{time},
            end_index   => $max_idx,
            end_time    => $candles->[$max_idx]{time},
            anchor_a_id => $a->{id},
            anchor_b_id => $b->{id},
            y1          => $a->{price},
            y2          => $y2,
            slope       => $slope,
            direction   => $dir,
        };
        push @$lines, $line;

        my $parallel = _parallel_channel($line, $opposite_pts, $candles, $max_idx);
        push @$channels, $parallel if $parallel;
    }
}

sub _parallel_channel {
    my ($line, $pts, $candles, $max_idx) = @_;
    my ($best_off, $best_abs);
    my $line_kind = $line->{type};

    for my $p (@$pts) {
        next if $p->{index} < $line->{start_index};
        my $y = _line_y_at($line, $p->{index});
        my $off = $p->{price} - $y;
        next if $line_kind eq 'support' && $off < 0;
        next if $line_kind eq 'resistance' && $off > 0;
        my $abs = abs($off);
        if (!defined $best_abs || $abs > $best_abs) {
            $best_abs = $abs;
            $best_off = $off;
        }
    }

    return undef unless defined $best_off && $best_abs > 0;
    return {
        id          => _new_id(),
        type        => $line->{type} eq 'support' ? 'channel_upper' : 'channel_lower',
        timeframe   => $line->{timeframe},
        start_index => $line->{start_index},
        start_time  => $line->{start_time},
        end_index   => $line->{end_index},
        end_time    => $line->{end_time},
        y1          => $line->{y1} + $best_off,
        y2          => $line->{y2} + $best_off,
        slope       => $line->{slope},
        direction   => $line->{direction},
        source_line_id => $line->{id},
    };
}

sub _build_daily_levels {
    my ($candles, $daily, $atr_series, $max_idx, $tf) = @_;
    return [] if $tf eq 'D' || $tf eq 'W';
    return [] unless $daily && @$daily;

    my @daily_sorted = sort { ($a->{time} // '') cmp ($b->{time} // '') } @$daily;
    my @out;
    my $i = 0;

    while ($i <= $max_idx) {
        my $date = _date_of($candles->[$i]{time});
        my $start = $i;
        my $end = $i;
        while ($end + 1 <= $max_idx && _date_of($candles->[$end + 1]{time}) eq $date) {
            $end++;
        }

        my $prev = _prev_daily_for_date(\@daily_sorted, $date);
        if ($prev) {
            my $body_high = max($prev->{open}, $prev->{close});
            my $body_low  = min($prev->{open}, $prev->{close});
            my @levels = (
                ['prev_daily_wick_high', 'PD Wick H', $prev->{high}, 'wick_high'],
                ['prev_daily_body_high', 'PD Body H', $body_high,    'body_high'],
                ['prev_daily_body_low',  'PD Body L', $body_low,     'body_low'],
                ['prev_daily_wick_low',  'PD Wick L', $prev->{low},  'wick_low'],
            );
            for my $lv (@levels) {
                my ($type, $label, $price, $zone) = @$lv;
                push @out, {
                    id          => _new_id(),
                    type        => $type,
                    label       => $label,
                    timeframe   => $tf,
                    daily_time  => $prev->{time},
                    start_index => $start,
                    start_time  => $candles->[$start]{time},
                    end_index   => $end,
                    end_time    => $candles->[$end]{time},
                    price       => $price,
                    zone        => $zone,
                    near        => _touches_daily_level($candles, $atr_series, $start, $end, $price),
                };
            }
        }

        $i = $end + 1;
    }

    return \@out;
}

sub _strategy_liquidity_links {
    my ($levels, $events, $max_idx) = @_;
    my @out;
    for my $ev (@{ $events // [] }) {
        next if ($ev->{swept_index} // 9_999_999) > $max_idx;
        push @out, {
            id => _new_id(),
            liquidity_event_id => $ev->{id},
            index => $ev->{swept_index},
            classification => $ev->{classification},
            projected_effect => $ev->{projected_effect},
        };
    }
    return \@out;
}

sub _volume_average {
    my ($candles, $max_idx) = @_;
    my @avg;
    my $sum = 0;
    for my $i (0 .. $max_idx) {
        $sum += $candles->[$i]{volume} // 0;
        $sum -= $candles->[$i - VOL_WIN]{volume} // 0 if $i >= VOL_WIN;
        my $cnt = $i + 1 < VOL_WIN ? $i + 1 : VOL_WIN;
        $avg[$i] = $cnt ? $sum / $cnt : 1;
    }
    return \@avg;
}

sub _last_opposite_candle {
    my ($candles, $from, $bullish_impulse) = @_;
    my $min_i = $from - ZONE_LOOKBACK + 1;
    $min_i = 0 if $min_i < 0;

    for (my $j = $from; $j >= $min_i; $j--) {
        my $c = $candles->[$j];
        return $j if $bullish_impulse && $c->{close} < $c->{open};
        return $j if !$bullish_impulse && $c->{close} > $c->{open};
    }
    return undef;
}

sub _zone_bounds {
    my ($c, $type) = @_;
    if ($type eq 'demand') {
        return ($c->{low}, max($c->{open}, $c->{close}));
    }
    return (min($c->{open}, $c->{close}), $c->{high});
}

sub _resolve_zone {
    my ($candles, $from, $max_idx, $type, $low, $high) = @_;
    for my $i ($from .. $max_idx) {
        my $c = $candles->[$i];
        if ($type eq 'demand') {
            if ($c->{close} < $low) {
                return { active => 0, status => 'invalidated', end_index => $i, end_time => $c->{time} };
            }
            if ($c->{low} <= $high) {
                return { active => 0, status => 'mitigated', end_index => $i, end_time => $c->{time} };
            }
        }
        else {
            if ($c->{close} > $high) {
                return { active => 0, status => 'invalidated', end_index => $i, end_time => $c->{time} };
            }
            if ($c->{high} >= $low) {
                return { active => 0, status => 'mitigated', end_index => $i, end_time => $c->{time} };
            }
        }
    }
    return { active => 1, status => 'active', end_index => undef, end_time => undef };
}

sub _sr_broken {
    my ($candles, $cl, $max_idx) = @_;
    for my $i (($cl->{last_index} // 0) + 1 .. $max_idx) {
        my $c = $candles->[$i];
        if ($cl->{type} eq 'resistance' && $c->{close} > $cl->{price} + $cl->{tolerance}) {
            return { index => $i, time => $c->{time} };
        }
        if ($cl->{type} eq 'support' && $c->{close} < $cl->{price} - $cl->{tolerance}) {
            return { index => $i, time => $c->{time} };
        }
    }
    return undef;
}

sub _near_event {
    my ($events, $idx, $pad) = @_;
    return undef unless $events && @$events;
    my @near = grep {
        defined $_->{swept_index} && abs($_->{swept_index} - $idx) <= $pad
    } @$events;
    return @near ? $near[-1] : undef;
}

sub _near_structure {
    my ($structs, $idx, $pad) = @_;
    return undef unless $structs && @$structs;
    my @near = grep {
        defined $_->{break_index} && abs($_->{break_index} - $idx) <= $pad
    } @$structs;
    return @near ? $near[-1] : undef;
}

sub _touches_daily_level {
    my ($candles, $atr_series, $start, $end, $price) = @_;
    for my $i ($start .. $end) {
        my $atr = _atr_at($atr_series, $candles, $i);
        my $tol = $atr > 0 ? $atr * 0.30 : 0.01;
        return 1 if abs(($candles->[$i]{close} // 0) - $price) <= $tol;
        return 1 if $candles->[$i]{low} <= $price && $candles->[$i]{high} >= $price;
    }
    return 0;
}

sub _prev_daily_for_date {
    my ($daily, $date) = @_;
    my $prev;
    for my $d (@$daily) {
        my $d_date = _date_of($d->{time});
        last if $d_date ge $date;
        $prev = $d;
    }
    return $prev;
}

sub _date_of {
    my ($iso) = @_;
    return '' unless defined $iso;
    return substr($iso, 0, 10);
}

sub _high_low {
    my ($candles, $from, $to) = @_;
    my ($hi, $lo) = (-9**9, 9**9);
    for my $i ($from .. $to) {
        $hi = $candles->[$i]{high} if $candles->[$i]{high} > $hi;
        $lo = $candles->[$i]{low}  if $candles->[$i]{low}  < $lo;
    }
    return ($hi, $lo);
}

sub _line_y_at {
    my ($line, $idx) = @_;
    return $line->{y1} + $line->{slope} * ($idx - $line->{start_index});
}

sub _atr_at {
    my ($atr_series, $candles, $idx) = @_;
    return $atr_series->[$idx] if defined $atr_series && defined $atr_series->[$idx] && $atr_series->[$idx] > 0;
    my $from = $idx - 13;
    $from = 0 if $from < 0;
    my $sum = 0;
    my $cnt = 0;
    for my $i ($from .. $idx) {
        my $c = $candles->[$i];
        $sum += ($c->{high} - $c->{low});
        $cnt++;
    }
    return $cnt ? $sum / $cnt : 0;
}

1;
