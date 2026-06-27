package Market::Overlays::SMC_Structures;

use strict;
use warnings;

# ============================================================
#  Market::Overlays::SMC_Structures
#
#  Convierte pivots, estructuras, FVGs y Fibonacci de
#  SMC_Structures.pm en shapes visuales (OverlayShape).
#
#  No recalcula reglas de mercado. Solo transforma datos.
#
#  Shapes generados:
#    Pivots    -> etiqueta HH/HL/LH/LL en el precio del pivot
#    BOS ext   -> linea solida + etiqueta grande BOS
#    BOS int   -> linea discontinua + etiqueta menor BOS
#    CHoCH     -> linea + etiqueta CHoCH (solo si es real)
#    FVG norm  -> rectangulo semitransparente
#    FVG high  -> rectangulo destacado + etiqueta HIGH REACTION FVG
#    Fib level -> linea horizontal con ratio
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
            visible_by_default => 1,
        };
        $sid++;
    }

    # --- Lineas de BOS y CHoCH ---
    for my $st (@$structures) {
        next if $st->{break_index} > $max_idx;

        my $type = $st->{type};        # BOS | CHOCH
        my $dir  = $st->{direction};   # bullish | bearish
        my $scope = $st->{scope} // 'external';
        my $is_ext = $scope eq 'external';

        my $role  = lc("${type}_${dir}");
        my $style = $is_ext ? 'solid' : 'dashed';
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
            opacity     => $is_ext ? 0.9 : 0.55,
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
            opacity     => $is_ext ? 0.95 : 0.65,
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

        push @shapes, {
            id          => "FVG_$sid",
            source_type => 'fvg',
            source_id   => $fvg->{id},
            kind        => 'rectangle',
            timeframe   => $tf,
            x1_index    => $fvg->{start_index},
            x2_index    => ($fvg->{status} eq 'open' || $fvg->{status} eq 'partially_filled')
                           ? $max_idx : $fvg->{end_index} + 5,
            y1_price    => $fvg->{gap_low},
            y2_price    => $fvg->{gap_high},
            text        => $is_hr ? 'HIGH REACTION FVG' : undef,
            color_role  => $role,
            line_style  => 'solid',
            opacity     => $op < 0.05 ? 0.05 : $op,
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

    return \@shapes;
}

1;
