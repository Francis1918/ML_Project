package Market::Overlays::SMC_Structures;

use strict;
use warnings;

# ============================================================
#  Market::Overlays::SMC_Structures
#
#  Convierte pivots, estructuras, FVGs, Fibonacci y Premium/Discount de
#  SMC_Structures.pm en shapes visuales (OverlayShape).
#
#  No recalcula reglas de mercado. Solo transforma datos.
#
#  Shapes generados:
#    Pivots    -> etiqueta HH/HL/LH/LL en el precio del pivot
#    BOS ext   -> linea solida + etiqueta grande BOS
#    BOS int   -> linea discontinua + etiqueta menor BOS
#    CHoCH     -> linea + etiqueta CHoCH (solo si es real)
#    MSS       -> linea + etiqueta MSS derivada de CHoCH confirmado
#    FVG norm  -> rectangulo semitransparente
#    FVG high  -> rectangulo destacado + etiqueta HIGH REACTION FVG
#    Fib level -> linea horizontal con ratio
#    Premium/Discount -> zonas premium/discount + equilibrio 50%
#
#  Colores por rol:
#    pivot_hh / pivot_hl : verde
#    pivot_lh / pivot_ll : rojo
#    bos_bullish         : verde solido
#    bos_bearish         : rojo solido
#    choch_bullish       : cyan
#    choch_bearish       : naranja
#    fvg_bullish         : verde semitransparente
#    fvg_bearish         : rojo semitransparente
#    fvg_high_reaction   : amarillo
#    fib_level           : gris/blanco
# ============================================================

sub new { bless {}, shift }

sub build_shapes {
    my ($class_or_self, %args) = @_;

    my $pivots     = $args{pivots}            // [];
    my $structures = $args{structures}        // [];
    my $fvgs       = $args{fvgs}             // [];
    my $fib_sets   = $args{fib_sets}         // [];
    my $pd_zones   = $args{premium_discount_zones} // [];
    my $max_idx    = $args{max_visible_index} // 0;
    my $vis_start  = $args{visible_start}    // 0;
    my $tf         = $args{timeframe}        // '1m';

    my @shapes;
    my $sid = 1;

    # --- Etiquetas de Pivots (HH/HL/LH/LL) ---
    for my $p (@$pivots) {
        next unless defined $p->{label};
        next if $p->{confirmed_at} > $max_idx;

        my $is_high  = $p->{kind} eq 'high';
        my $is_major = ($p->{rank}//'minor') eq 'major';
        my $role = lc("pivot_$p->{label}");   # pivot_hh, pivot_hl, etc.

        push @shapes, {
            id          => "PV_$sid",
            source_type => 'smc',
            source_id   => $p->{id},
            kind        => 'label',
            timeframe   => $tf,
            x1_index    => $p->{index},
            x2_index    => $p->{index},
            y1_price    => $p->{price},
            y2_price    => $p->{price},
            text        => $p->{label} . ($is_major ? '' : ' '),
            color_role  => $role,
            line_style  => 'solid',
            opacity     => $is_major ? 0.95 : 0.65,
            structure_scope => $p->{scope},
            strength_class  => $p->{strength_class},
            visible_by_default => 1,
        };
        $sid++;

        if ($p->{strength_class}) {
            my $sw_role = $p->{strength_class};
            my $sw_text = $sw_role eq 'strong_high' ? 'Strong H'
                        : $sw_role eq 'weak_high'   ? 'Weak H'
                        : $sw_role eq 'strong_low'  ? 'Strong L'
                        :                              'Weak L';
            push @shapes, {
                id          => "PV_SW_$sid",
                source_type => 'smc',
                source_id   => $p->{id},
                kind        => 'label',
                timeframe   => $tf,
                x1_index    => $p->{index},
                x2_index    => $p->{index},
                y1_price    => $p->{price},
                y2_price    => $p->{price},
                text        => $sw_text,
                color_role  => $sw_role,
                line_style  => 'solid',
                opacity     => $is_major ? 0.58 : 0.36,
                structure_scope => $p->{scope},
                strength_class  => $p->{strength_class},
                visible_by_default => 1,
            };
            $sid++;
        }
    }

    # --- Lineas de BOS y CHoCH ---
    for my $st (@$structures) {
        next if $st->{break_index} > $max_idx;

        my $type = $st->{type};        # BOS | CHOCH | MSS
        my $dir  = $st->{direction};   # bullish | bearish
        my $scope = $st->{scope} // 'external';
        my $is_ext = $scope eq 'external';

        my $role  = lc("${type}_${dir}");
        my $style = $type eq 'MSS' ? 'dotted' : ($is_ext ? 'solid' : 'dashed');
        my $text  = $type . ($is_ext ? '' : ' (int)');

        # Linea horizontal en el precio roto
        push @shapes, {
            id          => "ST_LINE_$sid",
            source_type => 'smc',
            source_id   => $st->{id},
            kind        => 'line',
            timeframe   => $tf,
            x1_index    => $st->{break_index} - 3,
            x2_index    => $st->{break_index} + 3,
            y1_price    => $st->{break_price},
            y2_price    => $st->{break_price},
            text        => undef,
            color_role  => $role,
            line_style  => $style,
            opacity     => $type eq 'MSS' ? 0.72 : ($is_ext ? 0.9 : 0.55),
            structure_scope => $scope,
            visible_by_default => 1,
        };

        # Etiqueta del evento
        push @shapes, {
            id          => "ST_LABEL_$sid",
            source_type => 'smc',
            source_id   => $st->{id},
            kind        => 'label',
            timeframe   => $tf,
            x1_index    => $st->{break_index},
            x2_index    => $st->{break_index},
            y1_price    => $st->{break_price},
            y2_price    => $st->{break_price},
            text        => $text,
            color_role  => $role,
            line_style  => 'solid',
            opacity     => $type eq 'MSS' ? 0.78 : ($is_ext ? 0.95 : 0.65),
            structure_scope => $scope,
            visible_by_default => 1,
        };

        $sid++;
    }

    # --- Rectangulos de FVG ---
    for my $fvg (@$fvgs) {
        next if $fvg->{end_index} > $max_idx;

        my $is_hr = $fvg->{reaction_zone} ? 1 : 0;
        my $dir   = $fvg->{direction};
        my $role  = $is_hr ? 'fvg_high_reaction' : "fvg_$dir";
        my $op    = $fvg->{current_opacity} // $fvg->{opacity};
        my $x2    = $fvg->{project_until_index} // $max_idx;
        $x2 = $max_idx if $x2 > $max_idx;
        my $status = $fvg->{status} // 'active';

        push @shapes, {
            id          => "FVG_$sid",
            source_type => 'fvg',
            source_id   => $fvg->{id},
            kind        => 'rectangle',
            timeframe   => $tf,
            x1_index    => $fvg->{start_index},
            x2_index    => $status eq 'active' ? $max_idx : $x2,
            y1_price    => $fvg->{gap_low},
            y2_price    => $fvg->{gap_high},
            text        => $is_hr ? 'HIGH REACTION FVG' : undef,
            color_role  => $role,
            line_style  => $status eq 'invalidated' ? 'dotted' : 'solid',
            opacity     => $status eq 'active'
                           ? ($op < 0.05 ? 0.05 : $op)
                           : ($status eq 'mitigated' ? 0.16 : 0.08),
            visible_by_default => 1,
        };
        $sid++;
    }

    # --- Niveles Fibonacci ---
    for my $fs (@$fib_sets) {
        for my $lv (@{ $fs->{levels} }) {
            push @shapes, {
                id          => "FIB_$sid",
                source_type => 'fib',
                source_id   => $fs->{id},
                kind        => 'fib_line',
                timeframe   => $tf,
                x1_index    => $fs->{anchor_start_index},
                x2_index    => $max_idx,
                y1_price    => $lv->{price},
                y2_price    => $lv->{price},
                text        => sprintf("%.3f", $lv->{ratio}),
                color_role  => 'fib_level',
                line_style  => 'dotted',
                opacity     => 0.55,
                visible_by_default => 1,
            };
            $sid++;
        }
    }

    # --- Premium / Discount ---
    for my $pd (@$pd_zones) {
        next if ($pd->{confirmation_index} // $pd->{start_index} // 9_999_999) > $max_idx;
        my $x2 = $pd->{project_until_index} // $max_idx;
        $x2 = $max_idx if $x2 > $max_idx;

        push @shapes, {
            id          => "PD_PREMIUM_$sid",
            source_type => 'premium_discount',
            source_id   => $pd->{id},
            kind        => 'rectangle',
            timeframe   => $tf,
            x1_index    => $pd->{start_index},
            x2_index    => $x2,
            y1_price    => $pd->{premium_bottom},
            y2_price    => $pd->{premium_top},
            text        => 'Premium',
            color_role  => 'premium_zone',
            line_style  => 'solid',
            opacity     => 0.14,
            visible_by_default => 1,
        };
        $sid++;

        push @shapes, {
            id          => "PD_PREMIUM_LABEL_$sid",
            source_type => 'premium_discount',
            source_id   => $pd->{id},
            kind        => 'label',
            timeframe   => $tf,
            x1_index    => $x2,
            x2_index    => $x2,
            y1_price    => ($pd->{premium_top} + $pd->{premium_bottom}) / 2,
            y2_price    => ($pd->{premium_top} + $pd->{premium_bottom}) / 2,
            text        => 'Premium',
            color_role  => 'premium_zone',
            line_style  => 'solid',
            opacity     => 0.78,
            visible_by_default => 1,
        };
        $sid++;

        push @shapes, {
            id          => "PD_DISCOUNT_$sid",
            source_type => 'premium_discount',
            source_id   => $pd->{id},
            kind        => 'rectangle',
            timeframe   => $tf,
            x1_index    => $pd->{start_index},
            x2_index    => $x2,
            y1_price    => $pd->{discount_bottom},
            y2_price    => $pd->{discount_top},
            text        => 'Discount',
            color_role  => 'discount_zone',
            line_style  => 'solid',
            opacity     => 0.14,
            visible_by_default => 1,
        };
        $sid++;

        push @shapes, {
            id          => "PD_DISCOUNT_LABEL_$sid",
            source_type => 'premium_discount',
            source_id   => $pd->{id},
            kind        => 'label',
            timeframe   => $tf,
            x1_index    => $x2,
            x2_index    => $x2,
            y1_price    => ($pd->{discount_top} + $pd->{discount_bottom}) / 2,
            y2_price    => ($pd->{discount_top} + $pd->{discount_bottom}) / 2,
            text        => 'Discount',
            color_role  => 'discount_zone',
            line_style  => 'solid',
            opacity     => 0.78,
            visible_by_default => 1,
        };
        $sid++;

        push @shapes, {
            id          => "PD_EQ_$sid",
            source_type => 'premium_discount',
            source_id   => $pd->{id},
            kind        => 'fib_line',
            timeframe   => $tf,
            x1_index    => $pd->{start_index},
            x2_index    => $x2,
            y1_price    => $pd->{equilibrium_price},
            y2_price    => $pd->{equilibrium_price},
            text        => 'EQ 50%',
            color_role  => 'equilibrium',
            line_style  => 'dotted',
            opacity     => 0.72,
            visible_by_default => 1,
        };
        $sid++;
    }

    return \@shapes;
}

1;
