package Market::Overlays::Liquidity;

use strict;
use warnings;

# ============================================================
#  Market::Overlays::Liquidity
#
#  Convierte los niveles y eventos de Liquidity.pm en shapes
#  visuales (OverlayShape) para ser renderizados por el frontend.
#
#  No recalcula reglas de mercado. Solo transforma datos.
#
#  Shapes generados:
#    BSL  -> linea horizontal discontinua roja + etiqueta BSL
#    SSL  -> linea horizontal discontinua verde + etiqueta SSL
#    EQH  -> linea que conecta maximos iguales + etiqueta EQH
#    EQL  -> linea que conecta minimos iguales + etiqueta EQL
#    SWEEP_UP   -> marcador/linea roja + etiqueta SWEEP ^
#    SWEEP_DOWN -> marcador/linea verde + etiqueta SWEEP v
#    GRAB       -> etiqueta naranja LQ GRAB
#    RUN        -> etiqueta azul LQ RUN
#
#  Colores por rol (el frontend mapea color_role a hex):
#    bsl        -> rojo      (#EF5350)
#    ssl        -> verde     (#26A69A)
#    eqh        -> naranja   (#FF9800)
#    eql        -> cian      (#00BCD4)
#    sweep_up   -> rojo      (#EF5350)
#    sweep_down -> verde     (#26A69A)
#    grab       -> naranja   (#FF9800)
#    run        -> azul      (#2196F3)
# ============================================================

sub new { bless {}, shift }

# ============================================================
#  Punto de entrada
#  Input:
#    levels  : arrayref de LiquidityLevel (de Liquidity.pm)
#    events  : arrayref de LiquidityEvent (de Liquidity.pm)
#    max_visible_index : int (respetar replay)
#    visible_start     : int (primera vela visible en pantalla)
#  Output:
#    arrayref de OverlayShape
# ============================================================

sub build_shapes {
    my ($class_or_self, %args) = @_;

    my $levels    = $args{levels}            // [];
    my $events    = $args{events}            // [];
    my $max_idx   = $args{max_visible_index} // 0;
    my $vis_start = $args{visible_start}     // 0;

    my @shapes;
    my $sid = 1;

    # --- Shapes para niveles activos y resueltos ---
    for my $lv (@$levels) {
        # Solo mostrar niveles que ya existen y son visibles
        next if $lv->{start_index} > $max_idx;

        my $x1 = $lv->{start_index};
        my $x2 = defined $lv->{end_index} ? $lv->{end_index} : $max_idx;
        $x2 = $max_idx if $x2 > $max_idx;

        my $role  = lc($lv->{type});   # bsl, ssl, eqh, eql
        my $label = uc($lv->{type});
        my $style = ($lv->{internal_or_external} // 'internal') eq 'external'
                    ? 'solid' : 'dashed';

        # Linea horizontal del nivel
        push @shapes, {
            id          => "LV_LINE_$sid",
            source_type => 'liquidity',
            source_id   => $lv->{id},
            kind        => 'line',
            timeframe   => $lv->{timeframe},
            x1_index    => $x1,
            x2_index    => $x2,
            y1_price    => $lv->{price},
            y2_price    => $lv->{price},
            text        => undef,
            color_role  => $role,
            line_style  => $style,
            opacity     => $lv->{active} ? 0.85 : 0.35,
            visible_by_default => 1,
        };

        # Etiqueta del nivel
        push @shapes, {
            id          => "LV_LABEL_$sid",
            source_type => 'liquidity',
            source_id   => $lv->{id},
            kind        => 'label',
            timeframe   => $lv->{timeframe},
            x1_index    => $x1,
            x2_index    => $x1,
            y1_price    => $lv->{price},
            y2_price    => $lv->{price},
            text        => $label,
            color_role  => $role,
            line_style  => 'solid',
            opacity     => $lv->{active} ? 0.9 : 0.4,
            visible_by_default => 1,
        };

        $sid++;
    }

    # --- Shapes para eventos de liquidez ---
    for my $ev (@$events) {
        next unless defined $ev->{swept_index};
        next if $ev->{swept_index} > $max_idx;

        my $class = $ev->{classification} // '';
        my ($role, $label, $kind);

        if ($class eq 'SWEEP') {
            $role  = $ev->{direction} eq 'up' ? 'sweep_up' : 'sweep_down';
            $label = $ev->{direction} eq 'up' ? 'SWEEP ^'  : 'SWEEP v';
            $kind  = 'marker';
        }
        elsif ($class eq 'GRAB') {
            $role  = 'grab';
            $label = 'LQ GRAB';
            $kind  = 'marker';
        }
        elsif ($class eq 'RUN') {
            $role  = 'run';
            $label = 'LQ RUN';
            $kind  = 'marker';
        }
        else { next }

        if (defined $ev->{swept_candle_high} && defined $ev->{swept_candle_low}) {
            push @shapes, {
                id          => "EV_CANDLE_$sid",
                source_type => 'liquidity',
                source_id   => $ev->{id},
                kind        => 'rectangle',
                timeframe   => $ev->{timeframe},
                x1_index    => $ev->{swept_index},
                x2_index    => $ev->{swept_index},
                y1_price    => $ev->{swept_candle_low},
                y2_price    => $ev->{swept_candle_high},
                text        => undef,
                color_role  => $role,
                line_style  => 'solid',
                opacity     => $class eq 'RUN' ? 0.24 : 0.18,
                visible_by_default => 1,
            };
        }

        push @shapes, {
            id          => "EV_$sid",
            source_type => 'liquidity',
            source_id   => $ev->{id},
            kind        => $kind,
            timeframe   => $ev->{timeframe},
            x1_index    => $ev->{swept_index},
            x2_index    => $ev->{resolved_index} // $ev->{swept_index},
            y1_price    => $ev->{swept_price},
            y2_price    => $ev->{swept_price},
            text        => $label,
            color_role  => $role,
            line_style  => 'solid',
            opacity     => 0.9,
            visible_by_default => 1,
        };

        $sid++;
    }

    return \@shapes;
}

1;
