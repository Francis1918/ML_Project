package Market::Overlays::Strategy_Builder;

use strict;
use warnings;

# ============================================================
#  Market::Overlays::Strategy_Builder
#
#  Convierte Strategy_Builder.pm en shapes visuales.
#  No recalcula reglas de trading.
# ============================================================

sub new { bless {}, shift }

sub build_shapes {
    my ($class_or_self, %args) = @_;

    my $strategy = $args{strategy}           // {};
    my $max_idx  = $args{max_visible_index}  // 0;
    my $tf       = $args{timeframe}          // '1m';

    my @shapes;
    my $sid = 1;

    _append_series_lines(\@shapes, \$sid, $strategy->{supertrend},   $max_idx, $tf, 'supertrend');
    _append_series_lines(\@shapes, \$sid, $strategy->{halftrend},    $max_idx, $tf, 'halftrend');
    _append_series_lines(\@shapes, \$sid, $strategy->{range_filter}, $max_idx, $tf, 'range_filter');

    _append_zones(\@shapes, \$sid, $strategy->{supply_zones}, 'supply', $max_idx, $tf);
    _append_zones(\@shapes, \$sid, $strategy->{demand_zones}, 'demand', $max_idx, $tf);
    _append_zones(\@shapes, \$sid, $strategy->{order_blocks}, 'order_block', $max_idx, $tf);

    _append_support_resistance(\@shapes, \$sid, $strategy->{support_resistance}, $max_idx, $tf);
    _append_trendlines(\@shapes, \$sid, $strategy->{trendlines}, $max_idx, $tf, 0);
    _append_trendlines(\@shapes, \$sid, $strategy->{channels}, $max_idx, $tf, 1);
    _append_daily_levels(\@shapes, \$sid, $strategy->{daily_levels}, $max_idx, $tf);

    return \@shapes;
}

sub _append_series_lines {
    my ($shapes, $sid_ref, $series, $max_idx, $tf, $name) = @_;
    return unless $series && @$series >= 2;

    for my $i (1 .. $#$series) {
        my $a = $series->[$i - 1];
        my $b = $series->[$i];
        next if ($b->{index} // 9_999_999) > $max_idx;
        next unless defined $a->{value} && defined $b->{value};

        my $dir = $b->{direction} // 'neutral';
        push @$shapes, {
            id          => uc($name) . "_LINE_$$sid_ref",
            source_type => 'strategy',
            source_id   => $b->{id},
            kind        => 'line',
            timeframe   => $tf,
            x1_index    => $a->{index},
            x2_index    => $b->{index},
            y1_price    => $a->{value},
            y2_price    => $b->{value},
            text        => undef,
            color_role  => "strategy_${name}_${dir}",
            line_style  => 'solid',
            opacity     => $name eq 'supertrend' ? 0.82 : 0.58,
            visible_by_default => 1,
        };
        $$sid_ref++;
    }
}

sub _append_zones {
    my ($shapes, $sid_ref, $zones, $kind, $max_idx, $tf) = @_;
    return unless $zones && @$zones;

    for my $z (@$zones) {
        next if ($z->{confirmed_index} // $z->{start_index} // 9_999_999) > $max_idx;
        my $x2 = defined $z->{end_index} ? $z->{end_index} : $max_idx;
        $x2 = $max_idx if $x2 > $max_idx;

        my $role;
        my $label;
        if ($kind eq 'order_block') {
            $role = ($z->{ob_side} // '') eq 'bullish' ? 'order_block_bullish' : 'order_block_bearish';
            $label = ($z->{ob_side} // '') eq 'bullish' ? 'Bull OB' : 'Bear OB';
        }
        else {
            $role = $kind;
            $label = ucfirst($kind);
        }

        push @$shapes, {
            id          => uc($kind) . "_ZONE_$$sid_ref",
            source_type => 'strategy',
            source_id   => $z->{id},
            kind        => 'rectangle',
            timeframe   => $tf,
            x1_index    => $z->{start_index},
            x2_index    => $x2,
            y1_price    => $z->{low},
            y2_price    => $z->{high},
            text        => $label,
            color_role  => $role,
            line_style  => 'solid',
            opacity     => $z->{active} ? 0.22 : 0.10,
            visible_by_default => 1,
        };
        $$sid_ref++;
    }
}

sub _append_support_resistance {
    my ($shapes, $sid_ref, $levels, $max_idx, $tf) = @_;
    return unless $levels && @$levels;

    for my $lv (@$levels) {
        next if ($lv->{first_index} // 9_999_999) > $max_idx;
        my $x2 = defined $lv->{end_index} ? $lv->{end_index} : $max_idx;
        $x2 = $max_idx if $x2 > $max_idx;

        push @$shapes, {
            id          => "SR_LINE_$$sid_ref",
            source_type => 'strategy',
            source_id   => $lv->{id},
            kind        => 'line',
            timeframe   => $tf,
            x1_index    => $lv->{first_index},
            x2_index    => $x2,
            y1_price    => $lv->{price},
            y2_price    => $lv->{price},
            text        => undef,
            color_role  => $lv->{type},
            line_style  => $lv->{active} ? 'dashed' : 'dotted',
            opacity     => $lv->{active} ? 0.58 : 0.30,
            visible_by_default => 1,
        };
        push @$shapes, {
            id          => "SR_LABEL_$$sid_ref",
            source_type => 'strategy',
            source_id   => $lv->{id},
            kind        => 'label',
            timeframe   => $tf,
            x1_index    => $x2,
            x2_index    => $x2,
            y1_price    => $lv->{price},
            y2_price    => $lv->{price},
            text        => ($lv->{type} eq 'support' ? 'Support' : 'Resistance') . " x$lv->{touches}",
            color_role  => $lv->{type},
            line_style  => 'solid',
            opacity     => 0.68,
            visible_by_default => 1,
        };
        $$sid_ref++;
    }
}

sub _append_trendlines {
    my ($shapes, $sid_ref, $lines, $max_idx, $tf, $is_channel) = @_;
    return unless $lines && @$lines;

    for my $ln (@$lines) {
        next if ($ln->{start_index} // 9_999_999) > $max_idx;
        my $x2 = $ln->{end_index} // $max_idx;
        $x2 = $max_idx if $x2 > $max_idx;
        my $role = $is_channel
            ? ($ln->{direction} eq 'bullish' ? 'channel_bullish' : 'channel_bearish')
            : ($ln->{direction} eq 'bullish' ? 'trendline_bullish' : 'trendline_bearish');

        push @$shapes, {
            id          => ($is_channel ? 'CHANNEL' : 'TRENDLINE') . "_$$sid_ref",
            source_type => 'strategy',
            source_id   => $ln->{id},
            kind        => 'line',
            timeframe   => $tf,
            x1_index    => $ln->{start_index},
            x2_index    => $x2,
            y1_price    => $ln->{y1},
            y2_price    => $ln->{y2},
            text        => undef,
            color_role  => $role,
            line_style  => $is_channel ? 'dotted' : 'solid',
            opacity     => $is_channel ? 0.38 : 0.58,
            visible_by_default => 1,
        };
        $$sid_ref++;
    }
}

sub _append_daily_levels {
    my ($shapes, $sid_ref, $levels, $max_idx, $tf) = @_;
    return unless $levels && @$levels;

    for my $lv (@$levels) {
        next if ($lv->{start_index} // 9_999_999) > $max_idx;
        my $x2 = $lv->{end_index} // $max_idx;
        $x2 = $max_idx if $x2 > $max_idx;
        my $role = ($lv->{zone} // '') =~ /body/ ? 'daily_body' : 'daily_wick';

        push @$shapes, {
            id          => "DAILY_LINE_$$sid_ref",
            source_type => 'strategy',
            source_id   => $lv->{id},
            kind        => 'line',
            timeframe   => $tf,
            x1_index    => $lv->{start_index},
            x2_index    => $x2,
            y1_price    => $lv->{price},
            y2_price    => $lv->{price},
            text        => undef,
            color_role  => $role,
            line_style  => $lv->{near} ? 'solid' : 'dotted',
            opacity     => $lv->{near} ? 0.60 : 0.34,
            visible_by_default => 1,
        };
        push @$shapes, {
            id          => "DAILY_LABEL_$$sid_ref",
            source_type => 'strategy',
            source_id   => $lv->{id},
            kind        => 'label',
            timeframe   => $tf,
            x1_index    => $x2,
            x2_index    => $x2,
            y1_price    => $lv->{price},
            y2_price    => $lv->{price},
            text        => $lv->{label},
            color_role  => $role,
            line_style  => 'solid',
            opacity     => $lv->{near} ? 0.78 : 0.50,
            visible_by_default => 1,
        };
        $$sid_ref++;
    }
}

1;
