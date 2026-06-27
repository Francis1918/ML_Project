#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin";

use Mojolicious::Lite;

use Market::MarketData;
use Market::Indicators::ATR;
use Market::IndicatorManager;
use Market::Indicators::Liquidity;
use Market::Indicators::SMC_Structures;
use Market::Indicators::MarketRegime;
use Market::Overlays::Liquidity;
use Market::Overlays::SMC_Structures;

# ============================================================
#  app.pl  -- Punto de entrada / servidor del sistema.
#  Fase 2 Avance 1:
#  - Lee CSV (1m) y construye 5m/15m/1h/2h/4h/D/W.
#  - Calcula ATR por timeframe.
#  - Calcula Liquidity, SMC_Structures y MarketRegime por TF.
#  - Sirve el frontend y expone API JSON con soporte replay.
# ============================================================

push @{ app->static->paths }, "$FindBin::Bin/../frontend";

my $CSV    = "$FindBin::Bin/data/2026_03.csv";
my @TFS    = qw(1m 5m 15m 1h 2h 4h D W);
my $PERIOD = 14;

# HTF a proyectar sobre cada TF como liquidez externa
my %HTF_SOURCES = (
    '1m'  => [qw(1h 4h D)],
    '5m'  => [qw(1h 4h D)],
    '15m' => [qw(1h 4h D)],
    '1h'  => [qw(4h D)],
    '2h'  => [qw(4h D)],
    '4h'  => ['D'],
    'D'   => [],
    'W'   => [],
);

# --- 1) Leer CSV (1m) ---
my $market = Market::MarketData->new;
open(my $fh, '<', $CSV) or die "No pude abrir $CSV: $!";
my $primera = 1;
while (my $linea = <$fh>) {
    chomp $linea;
    if ($primera) { $primera = 0; next; }
    my ($t, $o, $h, $l, $c, $v) = split(/,/, $linea);
    $market->add_candle({
        time   => $t,
        open   => $o + 0,
        high   => $h + 0,
        low    => $l + 0,
        close  => $c + 0,
        volume => $v + 0,
    });
}
close($fh);

# --- 2) Construir todos los timeframes ---
$market->build_timeframes;

# --- 3) Manager ATR ---
my $mgr = Market::IndicatorManager->new;
$mgr->register('ATR', Market::Indicators::ATR->new($PERIOD));

# --- 4) Precalcular cache por TF ---
#  Cada TF guarda: candles, atr, anchors, overlays (liq + smc + regime)
my %CACHE;
for my $tf (@TFS) {
    $market->set_timeframe($tf);
    $mgr->reset_all;
    $mgr->update_last($market) for 1 .. $market->size;

    my $candles    = $market->get_slice(0, $market->last_index);
    my $atr_vals   = [ @{ $mgr->get('ATR') } ];
    my $max_idx    = $market->last_index;

    # Liquidity
    my $liq = Market::Indicators::Liquidity->compute(
        candles           => $candles,
        atr_series        => $atr_vals,
        max_visible_index => $max_idx,
        timeframe         => $tf,
    );

    # SMC (consume eventos de liquidez para contexto de FVG/calidad)
    my $smc = Market::Indicators::SMC_Structures->compute(
        candles           => $candles,
        atr_series        => $atr_vals,
        max_visible_index => $max_idx,
        timeframe         => $tf,
        liquidity_events  => $liq->{events},
    );

    # MarketRegime (consume ambos)
    my $regime_states = Market::Indicators::MarketRegime->compute(
        candles           => $candles,
        atr_series        => $atr_vals,
        liquidity_levels  => $liq->{levels},
        liquidity_events  => $liq->{events},
        structure_events  => $smc->{structures},
        pivots            => $smc->{pivots},
        max_visible_index => $max_idx,
        timeframe         => $tf,
    );

    # Overlay shapes (para renderizado en frontend)
    my $liq_shapes = Market::Overlays::Liquidity->build_shapes(
        levels            => $liq->{levels},
        events            => $liq->{events},
        max_visible_index => $max_idx,
    );
    my $smc_shapes = Market::Overlays::SMC_Structures->build_shapes(
        pivots            => $smc->{pivots},
        structures        => $smc->{structures},
        fvgs              => $smc->{fvgs},
        fib_sets          => $smc->{fib_sets},
        max_visible_index => $max_idx,
        timeframe         => $tf,
    );

    $CACHE{$tf} = {
        timeframe      => $tf,
        candles        => $candles,
        atr            => $atr_vals,
        anchors        => $market->compute_time_anchors,
        liq_levels     => $liq->{levels},
        liq_events     => $liq->{events},
        smc_pivots     => $smc->{pivots},
        smc_structures => $smc->{structures},
        smc_fvgs       => $smc->{fvgs},
        smc_fib_sets   => $smc->{fib_sets},
        regime_states  => $regime_states,
        liq_shapes     => $liq_shapes,
        smc_shapes     => $smc_shapes,
    };

    app->log->info(sprintf(
        "[%s] velas=%d  liq_lvls=%d  liq_evts=%d  pivots=%d  structs=%d  fvgs=%d  regime=%d  shapes=%d",
        $tf,
        scalar @$candles,
        scalar @{ $liq->{levels} },
        scalar @{ $liq->{events} },
        scalar @{ $smc->{pivots} },
        scalar @{ $smc->{structures} },
        scalar @{ $smc->{fvgs} },
        scalar @$regime_states,
        scalar(@$liq_shapes) + scalar(@$smc_shapes),
    ));
}

# ============================================================
#  Helper: aplica replay_index a datos base
# ============================================================

sub _apply_replay {
    my ($base, $replay_index) = @_;
    my %data    = %$base;
    my $total   = scalar @{ $base->{candles} };
    my $max_idx = $total - 1;
    my $replay  = 0;

    if (defined $replay_index && $replay_index =~ /^\d+$/) {
        my $ri  = $replay_index + 0;
        $max_idx = $ri < $max_idx ? $ri : $max_idx;
        $replay  = 1;
    }

    $data{candles}           = [ @{ $base->{candles} }[0 .. $max_idx] ];
    $data{atr}               = [ @{ $base->{atr}     }[0 .. $max_idx] ];
    $data{max_visible_index} = $max_idx;
    $data{replay}            = { active => $replay ? \1 : \0, index => $max_idx };
    return (\%data, $max_idx);
}

# ============================================================
#  Helper: filtra overlays hasta max_visible_index
# ============================================================

sub _clip_shapes {
    my ($shapes, $max_idx) = @_;
    my @result;
    for my $sh (@$shapes) {
        my $x1 = $sh->{x1_index} // 0;
        next if $x1 > $max_idx;
        my $x2 = $sh->{x2_index} // $x1;
        if ($x2 > $max_idx) {
            push @result, { %$sh, x2_index => $max_idx };
        } else {
            push @result, $sh;
        }
    }
    return \@result;
}

sub _clip_array {
    my ($arr, $max_idx, $key) = @_;
    return [ grep { ($_->{$key} // 0) <= $max_idx } @$arr ];
}

# ============================================================
#  Rutas
# ============================================================

get '/' => sub {
    my $c = shift;
    $c->reply->static('index.html');
};

# --- /api/info ---
get '/api/info' => sub {
    my $c = shift;
    my %counts;
    for my $tf (@TFS) {
        my $cache = $CACHE{$tf};
        $counts{$tf} = {
            candles    => scalar @{ $cache->{candles} },
            atr        => scalar @{ $cache->{atr} },
            liq_levels => scalar @{ $cache->{liq_levels} },
            liq_events => scalar @{ $cache->{liq_events} },
            pivots     => scalar @{ $cache->{smc_pivots} },
            structures => scalar @{ $cache->{smc_structures} },
            fvgs       => scalar @{ $cache->{smc_fvgs} },
        };
    }
    $c->render(json => {
        ok         => \1,
        period_atr => $PERIOD,
        timeframes => \@TFS,
        counts     => \%counts,
    });
};

# --- /api/candles : velas + ATR con soporte replay ---
get '/api/candles' => sub {
    my $c            = shift;
    my $tf           = $c->param('tf') // '1m';
    my $replay_index = $c->param('replay_index');

    unless (exists $CACHE{$tf}) {
        return $c->render(json=>{error=>"timeframe invalido: $tf"}, status=>400);
    }

    my ($data) = _apply_replay($CACHE{$tf}, $replay_index);
    $c->render(json => $data);
};

# --- /api/overlays : SMC + Liquidity + MarketRegime ---
# Params: tf, start, end, replay_index
get '/api/overlays' => sub {
    my $c            = shift;
    my $tf           = $c->param('tf') // '1m';
    my $replay_index = $c->param('replay_index');
    my $start        = ($c->param('start') // 0) + 0;
    my $end_p        = $c->param('end');

    unless (exists $CACHE{$tf}) {
        return $c->render(json=>{error=>"timeframe invalido: $tf"}, status=>400);
    }

    my $cache = $CACHE{$tf};
    my (undef, $max_idx) = _apply_replay($cache, $replay_index);
    my $is_replay = (defined $replay_index && $replay_index =~ /^\d+$/);

    $end_p = defined $end_p ? ($end_p + 0 < $max_idx ? $end_p + 0 : $max_idx) : $max_idx;

    # Estado de regimen en la ultima vela visible
    my $regime_states = $cache->{regime_states};
    my $cur_regime    = ($regime_states && @$regime_states && $max_idx < scalar @$regime_states)
                        ? $regime_states->[$max_idx]
                        : { state => 'UNKNOWN', reason => 'fuera de rango', replay_safe => 1 };

    # Filtrar datos al rango visible
    my $liq_levels = _clip_array($cache->{liq_levels}, $max_idx, 'start_index');
    my $liq_events = _clip_array($cache->{liq_events}, $max_idx, 'swept_index');
    my $pivots     = _clip_array($cache->{smc_pivots},     $max_idx, 'confirmed_at');
    my $structures = _clip_array($cache->{smc_structures}, $max_idx, 'break_index');
    my $fvgs       = _clip_array($cache->{smc_fvgs},       $max_idx, 'end_index');
    my $fib_sets   = $cache->{smc_fib_sets};

    # Shapes ya precalculados, solo recortar
    my $liq_shapes = _clip_shapes($cache->{liq_shapes}, $max_idx);
    my $smc_shapes = _clip_shapes($cache->{smc_shapes}, $max_idx);

    # Proyeccion HTF: niveles activos de temporalidades superiores como liquidez externa
    my @htf_shapes;
    for my $htf (@{ $HTF_SOURCES{$tf} // [] }) {
        next unless exists $CACHE{$htf};
        for my $lv (@{ $CACHE{$htf}{liq_levels} // [] }) {
            next unless $lv->{active};
            my $role = lc($lv->{type});
            # Linea horizontal que abarca todo el rango visible
            push @htf_shapes, {
                id          => "HTF_${htf}_$lv->{id}",
                source_type => 'liquidity',
                source_id   => $lv->{id},
                kind        => 'line',
                timeframe   => $htf,
                x1_index    => 0,
                x2_index    => $max_idx,
                y1_price    => $lv->{price},
                y2_price    => $lv->{price},
                color_role  => $role,
                line_style  => 'solid',
                opacity     => 0.50,
                visible_by_default => 1,
            };
            # Etiqueta en el indice mas reciente visible (esquina derecha)
            push @htf_shapes, {
                id          => "HTF_LBL_${htf}_$lv->{id}",
                source_type => 'liquidity',
                source_id   => $lv->{id},
                kind        => 'label',
                timeframe   => $htf,
                x1_index    => $max_idx,
                x2_index    => $max_idx,
                y1_price    => $lv->{price},
                y2_price    => $lv->{price},
                text        => uc($lv->{type}) . " $htf",
                color_role  => $role,
                line_style  => 'solid',
                opacity     => 0.65,
                visible_by_default => 1,
            };
        }
    }

    $c->render(json => {
        timeframe         => $tf,
        visible_range     => { start => $start, end => $end_p },
        max_visible_index => $max_idx,
        replay            => {
            active => $is_replay ? \1 : \0,
            index  => $max_idx,
        },
        market_regime => {
            state                  => $cur_regime->{state},
            previous_state         => $cur_regime->{previous_state},
            reason                 => $cur_regime->{reason},
            confidence_score       => $cur_regime->{confidence_score},
            nearest_liquidity_id   => $cur_regime->{nearest_liquidity_id},
            last_liquidity_event_id=> $cur_regime->{last_liquidity_event_id},
            last_structure_event_id=> $cur_regime->{last_structure_event_id},
            replay_safe            => \1,
        },
        liquidity => {
            levels         => $liq_levels,
            events         => $liq_events,
            overlay_shapes => [@$liq_shapes, @htf_shapes],
        },
        smc => {
            pivots         => $pivots,
            structures     => $structures,
            fvgs           => $fvgs,
            fib_sets       => $fib_sets,
            overlay_shapes => $smc_shapes,
        },
    });
};

app->start;
