#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin";

use Mojolicious::Lite;
use Time::HiRes qw(gettimeofday tv_interval);

use Market::MarketData;
use Market::SMCConfig;
use Market::Indicators::ATR;
use Market::IndicatorManager;
use Market::Indicators::Liquidity;
use Market::Indicators::SMC_Structures;
use Market::Indicators::MarketRegime;
use Market::Indicators::Strategy_Builder;
use Market::Overlays::Liquidity;
use Market::Overlays::SMC_Structures;
use Market::Overlays::Strategy_Builder;

# ============================================================
#  app.pl  -- Punto de entrada / servidor del sistema.
#  Optimizaciones:
#  - Carga CSV + build_timeframes al inicio (rapido).
#  - /api/candles calcula solo velas/ATR POR TF cuando se pide
#    por primera vez (cache rapida).
#  - /api/overlays calcula indicadores y shapes solo cuando se pide
#    por primera vez (cache pesada, desacoplada de candles).
#  - /api/candles devuelve ventana de hasta $DEFAULT_LIMIT velas.
#  - /api/overlays filtra shapes realmente al rango visible y
#    normaliza indices a coordenadas locales de la ventana.
#  - Time::HiRes para medir cada etapa de computo.
# ============================================================

push @{ app->static->paths }, "$FindBin::Bin/../frontend";

my $CSV           = "$FindBin::Bin/data/2026_06_29.csv";
my @TFS           = qw(1m 5m 15m 1h 2h 4h D W);
my $SMC_CONFIG    = Market::SMCConfig->defaults;
my $PERIOD        = $SMC_CONFIG->{atrPeriod};
my $DEFAULT_LIMIT = 500;
my $OVERLAY_LOOKBACK = $SMC_CONFIG->{overlayLookback};
my $FULL_OVERLAY_MAX_CANDLES = 6_000;
my $HTF_ACTIVE_MAX_LEVELS_PER_TF = $SMC_CONFIG->{maxHtfLevelsPerTimeframe};
my $HTF_SWING_K = $SMC_CONFIG->{swingLookback};
my $HTF_EQ_FACTOR = $SMC_CONFIG->{equalHighLowAtrTolerance};
my $HTF_EQ_LOOKBACK_SWINGS = 120;

my %HTF_SOURCES = (
    '1m'  => [qw(5m 15m 1h 4h D W)],
    '5m'  => [qw(15m 1h 4h D W)],
    '15m' => [qw(1h 4h D W)],
    '1h'  => [qw(2h 4h D W)],
    '2h'  => [qw(4h D W)],
    '4h'  => [qw(D W)],
    'D'   => ['W'],
    'W'   => [],
);

# ============================================================
#  1) Leer CSV (1m) — obligatorio para build_timeframes
# ============================================================

my $t_csv = [gettimeofday];
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
app->log->info(sprintf("[startup] CSV leido en %.3fs (%d velas 1m)",
    tv_interval($t_csv), scalar @{ $market->{data}{'1m'} }));

# ============================================================
#  2) build_timeframes — agrega velas; rapido, sin indicadores
# ============================================================

my $t_tf = [gettimeofday];
$market->build_timeframes;
app->log->info(sprintf("[startup] build_timeframes en %.3fs", tv_interval($t_tf)));

# ============================================================
#  3) IndicatorManager compartido (se resetea en cada build)
# ============================================================

my $mgr = Market::IndicatorManager->new;
$mgr->register('ATR', Market::Indicators::ATR->new($PERIOD));

# ============================================================
#  Cache lazy por TF.
#  Primero se llena la parte rapida (candles/ATR/anchors).
#  La parte pesada completa queda para debug/full.
#  La UI normal calcula overlays solo para la ventana visible + lookback.
# ============================================================

my %CACHE;
my %WINDOW_OVERLAY_CACHE;
my %HTF_LIQUIDITY_SHAPE_CACHE;
my %SMC_EVENT_CACHE;

sub _build_market_cache_for {
    my ($tf) = @_;
    return if exists $CACHE{$tf} && $CACHE{$tf}{market_ready};

    my $t0 = [gettimeofday];
    app->log->info("[cache][market] Construyendo TF=$tf ...");

    $market->set_timeframe($tf);
    $mgr->reset_all;
    $mgr->update_last($market) for 1 .. $market->size;

    my $candles  = $market->get_slice(0, $market->last_index);
    my $atr_vals = [ @{ $mgr->get('ATR') } ];
    my $anchors  = $market->compute_time_anchors;

    $CACHE{$tf} = {
        %{ $CACHE{$tf} // {} },
        market_ready => 1,
        timeframe    => $tf,
        candles      => $candles,
        atr          => $atr_vals,
        anchors      => $anchors,
    };

    app->log->info(sprintf(
        "[cache][market][%s] LISTO en %.3fs | velas=%d anchors=%d",
        $tf, tv_interval($t0), scalar @$candles, scalar @$anchors,
    ));
}

sub _build_overlay_cache_for {
    my ($tf) = @_;
    _build_market_cache_for($tf);
    return if $CACHE{$tf}{overlays_ready};

    my $t0 = [gettimeofday];
    app->log->info("[cache][overlays] Construyendo TF=$tf ...");

    my $cache    = $CACHE{$tf};
    my $candles  = $cache->{candles};
    my $atr_vals = $cache->{atr};
    my $max_idx  = $#$candles;

    # Liquidity
    my $t1 = [gettimeofday];
    my $liq = Market::Indicators::Liquidity->compute(
        candles           => $candles,
        atr_series        => $atr_vals,
        max_visible_index => $max_idx,
        timeframe         => $tf,
        volume_sources    => _volume_sources(),
        volume_until_time => _add_minutes_iso($candles->[$max_idx]{time}, _tf_minutes($tf)),
    );
    app->log->info(sprintf("[cache][%s] Liquidity en %.3fs", $tf, tv_interval($t1)));

    # SMC
    my $t2 = [gettimeofday];
    my $smc = Market::Indicators::SMC_Structures->compute(
        candles           => $candles,
        atr_series        => $atr_vals,
        max_visible_index => $max_idx,
        timeframe         => $tf,
        liquidity_events  => $liq->{events},
        config            => $SMC_CONFIG,
    );
    app->log->info(sprintf("[cache][%s] SMC en %.3fs", $tf, tv_interval($t2)));

    # MarketRegime
    my $t3 = [gettimeofday];
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
    app->log->info(sprintf("[cache][%s] MarketRegime en %.3fs", $tf, tv_interval($t3)));

    # Strategy Builder
    my $t3b = [gettimeofday];
    my $strategy = Market::Indicators::Strategy_Builder->compute(
        candles           => $candles,
        atr_series        => $atr_vals,
        liquidity_levels  => $liq->{levels},
        liquidity_events  => $liq->{events},
        structure_events  => $smc->{structures},
        pivots            => $smc->{pivots},
        max_visible_index => $max_idx,
        timeframe         => $tf,
        daily_candles     => _daily_candles_until(_add_minutes_iso($candles->[$max_idx]{time}, _tf_minutes($tf)), $tf),
    );
    app->log->info(sprintf("[cache][%s] Strategy_Builder en %.3fs", $tf, tv_interval($t3b)));

    # Overlay shapes
    my $t4 = [gettimeofday];
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
        premium_discount_zones => $smc->{premium_discount_zones},
        max_visible_index => $max_idx,
        timeframe         => $tf,
    );
    my $strategy_shapes = Market::Overlays::Strategy_Builder->build_shapes(
        strategy          => $strategy,
        max_visible_index => $max_idx,
        timeframe         => $tf,
    );
    app->log->info(sprintf("[cache][%s] Shapes en %.3fs", $tf, tv_interval($t4)));

    $CACHE{$tf} = {
        %$cache,
        overlays_ready => 1,
        timeframe      => $tf,
        liq_levels     => $liq->{levels},
        liq_events     => $liq->{events},
        smc_pivots     => $smc->{pivots},
        smc_structures => $smc->{structures},
        smc_fvgs       => $smc->{fvgs},
        smc_fib_sets   => $smc->{fib_sets},
        smc_premium_discount_zones => $smc->{premium_discount_zones},
        regime_states  => $regime_states,
        strategy       => $strategy,
        liq_shapes     => $liq_shapes,
        smc_shapes     => $smc_shapes,
        strategy_shapes => $strategy_shapes,
    };

    app->log->info(sprintf(
        "[cache][overlays][%s] LISTO en %.3fs | liq_lvls=%d pivots=%d structs=%d fvgs=%d shapes=%d",
        $tf, tv_interval($t0),
        scalar @{ $liq->{levels} },
        scalar @{ $smc->{pivots} },
        scalar @{ $smc->{structures} },
        scalar @{ $smc->{fvgs} },
        scalar(@$liq_shapes) + scalar(@$smc_shapes) + scalar(@$strategy_shapes),
    ));
}

sub _build_window_overlay_for {
    my ($tf, $win_start, $win_end) = @_;
    _build_market_cache_for($tf);

    my $cache = $CACHE{$tf};
    my $key = join(':', $tf, $win_start, $win_end, $OVERLAY_LOOKBACK);
    return $WINDOW_OVERLAY_CACHE{$key} if exists $WINDOW_OVERLAY_CACHE{$key};

    my $t0 = [gettimeofday];
    my $calc_start = $win_start - $OVERLAY_LOOKBACK;
    $calc_start = 0 if $calc_start < 0;
    my $calc_end = $win_end;

    my @candles = @{ $cache->{candles} }[$calc_start .. $calc_end];
    my @atr     = @{ $cache->{atr}     }[$calc_start .. $calc_end];
    my $max_idx = $#candles;
    my $vis_start_local = $win_start - $calc_start;
    my $vis_end_local   = $win_end   - $calc_start;

    my $visible_until_time = _add_minutes_iso($cache->{candles}[$win_end]{time}, _tf_minutes($tf));

    my $liq = Market::Indicators::Liquidity->compute(
        candles           => \@candles,
        atr_series        => \@atr,
        max_visible_index => $max_idx,
        timeframe         => $tf,
        volume_sources    => _volume_sources(),
        volume_until_time => $visible_until_time,
    );
    my $smc = Market::Indicators::SMC_Structures->compute(
        candles           => \@candles,
        atr_series        => \@atr,
        max_visible_index => $max_idx,
        timeframe         => $tf,
        liquidity_events  => $liq->{events},
        config            => $SMC_CONFIG,
    );
    my $regime_states = Market::Indicators::MarketRegime->compute(
        candles           => \@candles,
        atr_series        => \@atr,
        liquidity_levels  => $liq->{levels},
        liquidity_events  => $liq->{events},
        structure_events  => $smc->{structures},
        pivots            => $smc->{pivots},
        max_visible_index => $max_idx,
        timeframe         => $tf,
    );
    my $strategy = Market::Indicators::Strategy_Builder->compute(
        candles           => \@candles,
        atr_series        => \@atr,
        liquidity_levels  => $liq->{levels},
        liquidity_events  => $liq->{events},
        structure_events  => $smc->{structures},
        pivots            => $smc->{pivots},
        max_visible_index => $max_idx,
        timeframe         => $tf,
        daily_candles     => _daily_candles_until($visible_until_time, $tf),
    );

    my $liq_shapes_all = Market::Overlays::Liquidity->build_shapes(
        levels            => $liq->{levels},
        events            => $liq->{events},
        max_visible_index => $max_idx,
    );
    my $smc_shapes_all = Market::Overlays::SMC_Structures->build_shapes(
        pivots            => $smc->{pivots},
        structures        => $smc->{structures},
        fvgs              => $smc->{fvgs},
        fib_sets          => $smc->{fib_sets},
        premium_discount_zones => $smc->{premium_discount_zones},
        max_visible_index => $max_idx,
        timeframe         => $tf,
    );
    my $strategy_shapes_all = Market::Overlays::Strategy_Builder->build_shapes(
        strategy          => $strategy,
        max_visible_index => $max_idx,
        timeframe         => $tf,
    );

    my $liq_shapes = _clip_shapes_window(
        $liq_shapes_all, $vis_start_local, $vis_end_local, $calc_start, $cache->{candles},
    );
    my $smc_shapes = _clip_shapes_window(
        $smc_shapes_all, $vis_start_local, $vis_end_local, $calc_start, $cache->{candles},
    );
    my $strategy_shapes = _clip_shapes_window(
        $strategy_shapes_all, $vis_start_local, $vis_end_local, $calc_start, $cache->{candles},
    );
    my $cur_regime = ($regime_states && @$regime_states && $vis_end_local < scalar @$regime_states)
                     ? $regime_states->[$vis_end_local]
                     : { state => 'UNKNOWN', reason => 'fuera de rango', replay_safe => 1 };
    my $events = _normalize_smc_events(
        symbol       => 'DEFAULT',
        timeframe    => $tf,
        abs_offset   => $calc_start,
        abs_candles  => $cache->{candles},
        candles      => \@candles,
        atr_series   => \@atr,
        liquidity    => $liq,
        smc          => $smc,
        strategy     => $strategy,
        regime_state => $cur_regime,
    );

    my $result = {
        market_regime => $cur_regime,
        liquidity     => { overlay_shapes => $liq_shapes },
        smc           => { overlay_shapes => $smc_shapes },
        strategy      => { overlay_shapes => $strategy_shapes },
        events        => $events,
        stats         => {
            calc_start => $calc_start,
            calc_end   => $calc_end,
            win_start  => $win_start,
            win_end    => $win_end,
            candles    => scalar @candles,
            elapsed_s  => sprintf('%.3f', tv_interval($t0)),
        },
    };

    $WINDOW_OVERLAY_CACHE{$key} = $result;
    app->log->info(sprintf(
        "[cache][window][%s] LISTO en %.3fs | abs=%d..%d calc=%d..%d candles=%d shapes=%d",
        $tf, tv_interval($t0), $win_start, $win_end, $calc_start, $calc_end,
        scalar @candles, scalar(@$liq_shapes) + scalar(@$smc_shapes) + scalar(@$strategy_shapes),
    ));

    return $result;
}

# ============================================================
#  Helpers: filtrado y normalizacion de shapes a coordenadas
#  locales de ventana [win_start .. max_abs_idx]
# ============================================================

# Filtra shapes que intersectan [win_start, max_abs_idx] y
# normaliza x1_index/x2_index restando win_start.
sub _clip_shapes_window {
    my ($shapes, $win_start, $max_abs_idx, $abs_offset, $abs_candles) = @_;
    $abs_offset //= 0;
    my @result;
    for my $sh (@$shapes) {
        my $x1 = $sh->{x1_index} // 0;
        my $x2 = $sh->{x2_index} // $x1;
        next if $x1 > $max_abs_idx;
        next if $x2 < $win_start;
        my %s    = %$sh;
        my $clipped_x2 = $x2 > $max_abs_idx ? $max_abs_idx : $x2;
        my $abs_x1 = $x1 + $abs_offset;
        my $abs_x2 = $clipped_x2 + $abs_offset;
        $s{x1_index} = $x1 - $win_start;
        $s{x2_index} = $clipped_x2 - $win_start;
        $s{x1_abs_index} = $abs_x1;
        $s{x2_abs_index} = $abs_x2;
        $s{x1_time} = $abs_candles->[$abs_x1]{time}
            if $abs_candles && $abs_x1 >= 0 && $abs_x1 <= $#$abs_candles;
        $s{x2_time} = $abs_candles->[$abs_x2]{time}
            if $abs_candles && $abs_x2 >= 0 && $abs_x2 <= $#$abs_candles;
        push @result, \%s;
    }
    return \@result;
}

# Filtra array de objetos donde $key <= max_abs_idx
sub _clip_array {
    my ($arr, $max_idx, $key) = @_;
    return [ grep { ($_->{$key} // 0) <= $max_idx } @$arr ];
}

sub _normalize_smc_events {
    my (%args) = @_;
    my $symbol      = $args{symbol}    // 'DEFAULT';
    my $tf          = $args{timeframe} // '1m';
    my $abs_offset  = $args{abs_offset} // 0;
    my $abs_candles = $args{abs_candles} // [];
    my $local_c     = $args{candles} // [];
    my $atr_series   = $args{atr_series} // [];
    my $liq         = $args{liquidity} // {};
    my $smc         = $args{smc} // {};
    my $strategy    = $args{strategy} // {};
    my $regime      = $args{regime_state} // {};

    my @events;
    my %level_by_id = map { ($_->{id} // '') => $_ } @{ $liq->{levels} // [] };

    for my $p (@{ $smc->{pivots} // [] }) {
        next unless defined $p->{index};
        my $kind = ($p->{kind} // '') eq 'high' ? 'SWING_HIGH' : 'SWING_LOW';
        push @events, _event_base(
            id                => $p->{id},
            type              => $kind,
            symbol            => $symbol,
            timeframe         => $tf,
            start_index       => _abs_i($p->{index}, $abs_offset),
            start_time        => $p->{time},
            confirmation_index=> _abs_i($p->{confirmed_at}, $abs_offset),
            confirmation_time => $p->{confirmed_time},
            price             => $p->{price},
            direction         => ($p->{kind} // '') eq 'high' ? 'bearish' : 'bullish',
            strength          => (($p->{rank} // '') eq 'major') ? 0.85 : 0.55,
            status            => 'historical',
            related_swing_id  => $p->{id},
            metadata          => {
                label => $p->{label},
                rank  => $p->{rank},
                scope => $p->{scope},
                strength_class  => $p->{strength_class},
                strength_status => $p->{strength_status},
                broken_by_event_id => $p->{broken_by_event_id},
                broken_time => $p->{broken_time},
            },
        );
        if (($p->{label} // '') =~ /^(HH|HL|LH|LL)$/) {
            push @events, _event_base(
                id                => $p->{id} . '_' . $p->{label},
                type              => $p->{label},
                symbol            => $symbol,
                timeframe         => $tf,
                start_index       => _abs_i($p->{index}, $abs_offset),
                start_time        => $p->{time},
                confirmation_index=> _abs_i($p->{confirmed_at}, $abs_offset),
                confirmation_time => $p->{confirmed_time},
                price             => $p->{price},
                direction         => ($p->{kind} // '') eq 'high' ? 'bearish' : 'bullish',
                strength          => (($p->{rank} // '') eq 'major') ? 0.85 : 0.55,
                status            => 'historical',
                related_swing_id  => $p->{id},
                metadata          => {
                    swing_type      => $kind,
                    label           => $p->{label},
                    rank            => $p->{rank},
                    scope           => $p->{scope},
                    strength_class  => $p->{strength_class},
                    strength_status => $p->{strength_status},
                },
            );
        }
    }

    for my $lv (@{ $liq->{levels} // [] }) {
        next unless defined $lv->{start_index};
        my $tol = $lv->{tolerance} // 0;
        my $dir = (($lv->{type} // '') eq 'BSL' || ($lv->{type} // '') eq 'EQH') ? 'bullish' : 'bearish';
        push @events, _event_base(
            id                => $lv->{id},
            type              => 'LIQUIDITY_' . uc($lv->{type} // 'LEVEL'),
            symbol            => $symbol,
            timeframe         => $tf,
            source_timeframe  => $lv->{source_timeframe},
            start_index       => _abs_i($lv->{start_index}, $abs_offset),
            start_time        => $lv->{start_time},
            end_index         => defined $lv->{end_index} ? _abs_i($lv->{end_index}, $abs_offset) : undef,
            end_time          => $lv->{end_time},
            projection_end_index => defined $lv->{end_index}
                                    ? _abs_i($lv->{end_index}, $abs_offset)
                                    : _abs_i($#$local_c, $abs_offset),
            price             => $lv->{price},
            top               => defined $lv->{price} ? $lv->{price} + $tol : undef,
            bottom            => defined $lv->{price} ? $lv->{price} - $tol : undef,
            direction         => $dir,
            strength          => _event_strength($lv->{volume_weights}),
            status            => $lv->{active} ? 'active' : 'historical',
            related_level_id  => $lv->{id},
            metadata          => {
                origin   => $lv->{origin},
                state    => $lv->{state},
                scope    => $lv->{internal_or_external} // 'internal',
                pivots   => $lv->{pivots},
                tolerance=> $tol,
                volume_weights => $lv->{volume_weights},
            },
        );
    }

    for my $ev (@{ $liq->{events} // [] }) {
        next unless defined $ev->{swept_index};
        my $lv = $level_by_id{ $ev->{level_id} // '' };
        my $level_type = $lv ? ($lv->{type} // '') : '';
        my $class = $ev->{classification} // 'SWEEP';
        my $etype = $class eq 'RUN'  ? 'LIQUIDITY_RUN'
                  : $class eq 'GRAB' ? 'LIQUIDITY_GRAB'
                  : ($level_type eq 'SSL' || $level_type eq 'EQL') ? 'SWEEP_SSL'
                  : 'SWEEP_BSL';
        push @events, _event_base(
            id                => $ev->{id},
            type              => $etype,
            symbol            => $symbol,
            timeframe         => $tf,
            source_timeframe  => $ev->{source_timeframe},
            start_index       => _abs_i($ev->{swept_index}, $abs_offset),
            start_time        => $ev->{swept_time},
            end_index         => defined $ev->{resolved_index} ? _abs_i($ev->{resolved_index}, $abs_offset) : undef,
            end_time          => $ev->{resolved_time},
            confirmation_index=> defined $ev->{resolved_index} ? _abs_i($ev->{resolved_index}, $abs_offset) : undef,
            confirmation_time => $ev->{resolved_time},
            price             => $ev->{swept_price},
            top               => $ev->{swept_candle_high},
            bottom            => $ev->{swept_candle_low},
            direction         => ($ev->{direction} // '') eq 'up' ? 'bullish'
                                : ($ev->{direction} // '') eq 'down' ? 'bearish'
                                : 'neutral',
            strength          => _event_strength($ev->{volume_weights}),
            status            => 'historical',
            related_level_id  => $ev->{level_id},
            metadata          => {
                level_id     => $ev->{level_id},
                level_type   => $level_type,
                classification => $class,
                raw_direction => $ev->{direction},
                manipulation => ($class eq 'SWEEP' || $class eq 'GRAB') ? 1 : 0,
                projected_effect => $ev->{projected_effect},
                state_path   => $ev->{state_path},
                scope        => $ev->{internal_or_external} // 'internal',
                volume_weights => $ev->{volume_weights},
            },
        );
    }

    for my $st (@{ $smc->{structures} // [] }) {
        next unless defined $st->{break_index};
        my $scope = $st->{scope} // 'external';
        my $type = uc($st->{type} // 'STRUCTURE');
        my $etype = ($scope eq 'internal' && ($type eq 'BOS' || $type eq 'CHOCH'))
                    ? "INTERNAL_$type"
                    : $type;
        push @events, _event_base(
            id                => $st->{id},
            type              => $etype,
            symbol            => $symbol,
            timeframe         => $tf,
            start_index       => _abs_i($st->{break_index}, $abs_offset),
            start_time        => $st->{break_time},
            end_index         => _abs_i($st->{break_index}, $abs_offset),
            end_time          => $st->{break_time},
            confirmation_index=> _abs_i($st->{confirmation_index} // $st->{break_index}, $abs_offset),
            confirmation_time => $st->{confirmation_time} // $st->{break_time},
            price             => $st->{break_price},
            direction         => $st->{direction},
            strength          => $st->{quality_score} // 0.5,
            status            => $st->{status} && $st->{status} ne 'confirmed' ? $st->{status} : 'historical',
            related_swing_id  => $st->{pivot_id},
            metadata          => {
                scope        => $scope,
                pivot_id     => $st->{pivot_id},
                pivot_time   => $st->{pivot_time},
                source_choch_id => $st->{source_choch_id},
                previous_trend  => $st->{previous_trend},
                break_mode   => $st->{break_mode},
                real_or_false=> $st->{real_or_false},
                liquidity_context => $st->{liquidity_context},
            },
        );
    }

    for my $fvg (@{ $smc->{fvgs} // [] }) {
        next unless defined $fvg->{start_index};
        my $dir = $fvg->{direction} // 'neutral';
        push @events, _event_base(
            id                => $fvg->{id},
            type              => uc($dir) . '_FVG',
            symbol            => $symbol,
            timeframe         => $tf,
            start_index       => _abs_i($fvg->{start_index}, $abs_offset),
            start_time        => $fvg->{start_time},
            end_index         => _abs_i($fvg->{project_until_index} // $fvg->{end_index}, $abs_offset),
            end_time          => $fvg->{project_until_time} // $fvg->{end_time},
            confirmation_index=> _abs_i($fvg->{confirmation_index} // $fvg->{end_index}, $abs_offset),
            confirmation_time => $fvg->{confirmation_time} // $fvg->{end_time},
            projection_end_index => _abs_i($fvg->{project_until_index} // $fvg->{end_index}, $abs_offset),
            top               => $fvg->{gap_high},
            bottom            => $fvg->{gap_low},
            direction         => $dir,
            strength          => $fvg->{reaction_zone} ? 0.82 : 0.52,
            status            => $fvg->{status} // 'active',
            mitigation_time   => $fvg->{mitigation_time},
            invalidation_time => $fvg->{invalidation_time},
            metadata          => {
                middle_time => $fvg->{middle_time},
                source_liquidity_event_id => $fvg->{source_liquidity_event_id},
                reaction_zone => $fvg->{reaction_zone} ? 1 : 0,
                mitigation_time => $fvg->{mitigation_time},
                invalidation_time => $fvg->{invalidation_time},
            },
        );
    }

    for my $pd (@{ $smc->{premium_discount_zones} // [] }) {
        next unless defined $pd->{start_index};
        push @events, _event_base(
            id                => $pd->{id},
            type              => 'PREMIUM_DISCOUNT',
            symbol            => $symbol,
            timeframe         => $tf,
            start_index       => _abs_i($pd->{start_index}, $abs_offset),
            start_time        => $pd->{start_time},
            end_index         => _abs_i($pd->{project_until_index} // $#$local_c, $abs_offset),
            end_time          => $pd->{end_time},
            confirmation_index=> _abs_i($pd->{confirmation_index}, $abs_offset),
            confirmation_time => $pd->{confirmation_time},
            projection_end_index => _abs_i($pd->{project_until_index} // $#$local_c, $abs_offset),
            top               => $pd->{anchor_high},
            bottom            => $pd->{anchor_low},
            direction         => $pd->{direction},
            strength          => 0.60,
            status            => $pd->{status} // 'active',
            metadata          => {
                source_event_id   => $pd->{source_event_id},
                source_fib_id     => $pd->{source_fib_id},
                equilibrium_price => $pd->{equilibrium_price},
                premium           => { top => $pd->{premium_top}, bottom => $pd->{premium_bottom} },
                discount          => { top => $pd->{discount_top}, bottom => $pd->{discount_bottom} },
            },
        );
    }

    _append_fib_events(\@events, $symbol, $tf, $abs_offset, $local_c, $atr_series, $smc->{fib_sets});
    _append_liquidity_context_events(\@events, $symbol, $tf, $abs_offset, $local_c, $atr_series, $liq->{levels});
    _append_liquidity_run_candidates(\@events, $symbol, $tf, $abs_offset, $local_c, $atr_series, $liq->{levels});
    _append_strategy_events(\@events, $symbol, $tf, $abs_offset, $local_c, $atr_series, $strategy);

    @events = sort {
        ($a->{start_index} // 0) <=> ($b->{start_index} // 0)
            || ($a->{type} // '') cmp ($b->{type} // '')
    } @events;

    return \@events;
}

sub _append_strategy_events {
    my ($events, $symbol, $tf, $abs_offset, $local_c, $atr_series, $strategy) = @_;
    return unless $strategy;

    for my $ob (@{ $strategy->{order_blocks} // [] }) {
        my $side = $ob->{ob_side} // (($ob->{type} // '') =~ /bear/ ? 'bearish' : 'bullish');
        push @$events, _zone_event(
            $ob, $symbol, $tf, $abs_offset, $local_c,
            uc($side) . '_OB', $side, 0.72,
            { validation => $ob->{validation}, derived_from => $ob->{derived_from} },
        );
    }

    for my $z (@{ $strategy->{supply_zones} // [] }) {
        push @$events, _zone_event(
            $z, $symbol, $tf, $abs_offset, $local_c,
            'SUPPLY_ZONE', 'bearish', 0.58,
            { derived_from => $z->{derived_from}, structure_context_id => $z->{structure_context_id} },
        );
    }

    for my $z (@{ $strategy->{demand_zones} // [] }) {
        push @$events, _zone_event(
            $z, $symbol, $tf, $abs_offset, $local_c,
            'DEMAND_ZONE', 'bullish', 0.58,
            { derived_from => $z->{derived_from}, structure_context_id => $z->{structure_context_id} },
        );
    }

    _append_order_block_interactions($events, $symbol, $tf, $abs_offset, $local_c, $strategy->{order_blocks});
    _append_support_resistance_events($events, $symbol, $tf, $abs_offset, $local_c, $atr_series, $strategy->{support_resistance});
    _append_trendline_events($events, $symbol, $tf, $abs_offset, $local_c, $atr_series, $strategy->{trendlines}, $strategy->{channels});
    _append_daily_level_events($events, $symbol, $tf, $abs_offset, $local_c, $atr_series, $strategy->{daily_levels});
}

sub _zone_event {
    my ($z, $symbol, $tf, $abs_offset, $local_c, $type, $dir, $strength, $meta) = @_;
    my $status = $z->{status} // ($z->{active} ? 'active' : 'historical');
    my $mitigation_time   = $status eq 'mitigated'   ? $z->{end_time} : undef;
    my $invalidation_time = $status eq 'invalidated' ? $z->{end_time} : undef;
    return _event_base(
        id                => $z->{id},
        type              => $type,
        symbol            => $symbol,
        timeframe         => $tf,
        start_index       => _abs_i($z->{start_index}, $abs_offset),
        start_time        => $z->{start_time},
        end_index         => defined $z->{end_index} ? _abs_i($z->{end_index}, $abs_offset) : undef,
        end_time          => $z->{end_time},
        confirmation_index=> _abs_i($z->{confirmed_index} // $z->{displacement_index}, $abs_offset),
        confirmation_time => $z->{confirmed_time} // $z->{displacement_time},
        projection_end_index => defined $z->{end_index}
                                ? _abs_i($z->{end_index}, $abs_offset)
                                : _abs_i($#$local_c, $abs_offset),
        top               => $z->{high},
        bottom            => $z->{low},
        direction         => $dir,
        strength          => $strength,
        status            => $status,
        mitigation_time   => $mitigation_time,
        invalidation_time => $invalidation_time,
        metadata          => {
            displacement_index => _abs_i($z->{displacement_index}, $abs_offset),
            displacement_time  => $z->{displacement_time},
            displacement_range => $z->{displacement_range},
            volume_ratio       => $z->{volume_ratio},
            liquidity_context_id => $z->{liquidity_context_id},
            structure_context_id => $z->{structure_context_id},
            structure_context_type => $z->{structure_context_type},
            %{ $meta // {} },
        },
    );
}

sub _append_fib_events {
    my ($events, $symbol, $tf, $abs_offset, $candles, $atr_series, $fib_sets) = @_;
    return unless $fib_sets && @$fib_sets && $candles && @$candles;
    my @sets = @$fib_sets;
    @sets = @sets > 8 ? @sets[-8 .. -1] : @sets;
    my $last_idx = $#$candles;

    for my $fs (@sets) {
        next unless $fs->{levels} && @{ $fs->{levels} };
        my $start = $fs->{anchor_start_index};
        my $confirm = $fs->{break_index} // $fs->{anchor_end_index};
        next unless defined $start && defined $confirm;

        for my $lv (@{ $fs->{levels} }) {
            my $ratio = $lv->{ratio};
            my $price = $lv->{price};
            next unless defined $price;
            my $tol = _tol_at($atr_series, $candles, $confirm, 0.18);
            my $relation = _price_relation_to_level($candles->[$last_idx]{close}, $price, $tol);
            my $id = join('_', $fs->{id}, 'FIB', _ratio_id($ratio));

            push @$events, _event_base(
                id                => $id,
                type              => 'FIB_LEVEL',
                symbol            => $symbol,
                timeframe         => $tf,
                start_index       => _abs_i($start, $abs_offset),
                start_time        => $fs->{anchor_start_time},
                end_index         => _abs_i($last_idx, $abs_offset),
                end_time          => $candles->[$last_idx]{time},
                confirmation_index=> _abs_i($confirm, $abs_offset),
                confirmation_time => $fs->{break_time},
                projection_end_index => _abs_i($last_idx, $abs_offset),
                price             => $price,
                top               => $price + $tol,
                bottom            => $price - $tol,
                direction         => $fs->{direction} // 'neutral',
                strength          => 0.50,
                status            => 'active',
                metadata          => {
                    ratio             => $ratio,
                    source_fib_id     => $fs->{id},
                    source_event_id   => $fs->{source_event_id},
                    current_relation  => $relation,
                    tolerance         => $tol,
                },
            );

            my $near_idx = _first_near_level_index($candles, $atr_series, $confirm, $last_idx, $price, 0.18);
            next unless defined $near_idx;
            push @$events, _event_base(
                id                => $id . '_NEAR_' . _abs_i($near_idx, $abs_offset),
                type              => 'NEAR_FIB_LEVEL',
                symbol            => $symbol,
                timeframe         => $tf,
                start_index       => _abs_i($near_idx, $abs_offset),
                start_time        => $candles->[$near_idx]{time},
                confirmation_index=> _abs_i($near_idx, $abs_offset),
                confirmation_time => $candles->[$near_idx]{time},
                price             => $price,
                top               => $price + _tol_at($atr_series, $candles, $near_idx, 0.18),
                bottom            => $price - _tol_at($atr_series, $candles, $near_idx, 0.18),
                direction         => 'neutral',
                strength          => 0.42,
                status            => 'historical',
                metadata          => {
                    ratio           => $ratio,
                    source_fib_id   => $fs->{id},
                    relation        => _candle_relation_to_level($candles->[$near_idx], $price, _tol_at($atr_series, $candles, $near_idx, 0.18)),
                },
            );
        }
    }
}

sub _append_liquidity_context_events {
    my ($events, $symbol, $tf, $abs_offset, $candles, $atr_series, $levels) = @_;
    return unless $levels && @$levels && $candles && @$candles;
    my $last_idx = $#$candles;

    for my $lv (@$levels) {
        next unless defined $lv->{price} && defined $lv->{start_index};
        my $type = $lv->{type} // '';
        next unless $type =~ /^(EQH|EQL|BSL|SSL)$/;
        my $from = $lv->{start_index};
        $from = 0 if $from < 0;
        $from = $last_idx if $from > $last_idx;
        my $tol_factor = ($type eq 'EQH' || $type eq 'EQL') ? 0.25 : 0.18;
        my $near_idx = _first_near_level_index($candles, $atr_series, $from, $last_idx, $lv->{price}, $tol_factor);
        if (defined $near_idx) {
            my $ctx_type = $type eq 'EQH' ? 'NEAR_EQH'
                         : $type eq 'EQL' ? 'NEAR_EQL'
                         : $type eq 'BSL' ? 'NEAR_SWING_HIGH'
                         :                  'NEAR_SWING_LOW';
            push @$events, _level_context_event(
                $symbol, $tf, $abs_offset, $candles, $atr_series, $lv, $near_idx,
                $ctx_type, 'neutral', 'historical', $tol_factor,
            );
        }

        my $break_idx = _first_break_level_index($candles, $from, $last_idx, $lv->{price}, $lv->{tolerance} // 0, $type);
        next unless defined $break_idx;
        my $ctx_type = $type eq 'EQH' ? 'ABOVE_EQH'
                     : $type eq 'EQL' ? 'BELOW_EQL'
                     : $type eq 'BSL' ? 'ABOVE_SWING_HIGH'
                     :                  'BELOW_SWING_LOW';
        my $dir = ($type eq 'EQH' || $type eq 'BSL') ? 'bullish' : 'bearish';
        push @$events, _level_context_event(
            $symbol, $tf, $abs_offset, $candles, $atr_series, $lv, $break_idx,
            $ctx_type, $dir, 'historical', $tol_factor,
        );
    }
}

sub _append_liquidity_run_candidates {
    my ($events, $symbol, $tf, $abs_offset, $candles, $atr_series, $levels) = @_;
    return unless $levels && @$levels && $candles && @$candles;
    my $last_idx = $#$candles;

    for my $i (1 .. $last_idx) {
        my $c = $candles->[$i];
        my $range = ($c->{high} // 0) - ($c->{low} // 0);
        next unless $range > 0;
        my $atr = _atr_local($atr_series, $candles, $i);
        next unless $atr > 0 && $range >= $atr * 1.20;
        my $body = abs(($c->{close} // 0) - ($c->{open} // 0));
        next unless $body / $range >= 0.60;

        my $bullish = $c->{close} > $c->{open};
        my $target = _nearest_liquidity_target($levels, $i, $c, $atr, $bullish);
        next unless $target;

        my $price = $target->{price};
        next if $bullish && ($c->{high} // 0) >= $price;
        next if !$bullish && ($c->{low} // 0) <= $price;

        push @$events, _event_base(
            id                => join('_', 'LQ_RUN_CANDLE', $target->{id}, _abs_i($i, $abs_offset)),
            type              => 'LIQUIDITY_RUN_CANDLE',
            symbol            => $symbol,
            timeframe         => $tf,
            source_timeframe  => $target->{source_timeframe},
            start_index       => _abs_i($i, $abs_offset),
            start_time        => $c->{time},
            confirmation_index=> _abs_i($i, $abs_offset),
            confirmation_time => $c->{time},
            price             => $c->{close},
            top               => $c->{high},
            bottom            => $c->{low},
            direction         => $bullish ? 'bullish' : 'bearish',
            strength          => _clamp01(($range / ($atr * 2.0)) * 0.55 + ($body / $range) * 0.45),
            status            => 'historical',
            related_level_id  => $target->{id},
            metadata          => {
                target_level_type => $target->{type},
                target_price      => $price,
                distance_at_close => abs($price - $c->{close}),
                atr               => $atr,
                body_ratio        => sprintf('%.3f', $body / $range) + 0,
                range_atr_ratio   => sprintf('%.3f', $range / $atr) + 0,
            },
        );
    }
}

sub _append_order_block_interactions {
    my ($events, $symbol, $tf, $abs_offset, $candles, $obs) = @_;
    return unless $obs && @$obs && $candles && @$candles;
    my $last_idx = $#$candles;

    for my $ob (@$obs) {
        next unless defined $ob->{low} && defined $ob->{high};
        my $from = ($ob->{confirmed_index} // $ob->{start_index} // 0) + 1;
        $from = 0 if $from < 0;
        next if $from > $last_idx;
        my $to = defined $ob->{end_index} && $ob->{end_index} < $last_idx ? $ob->{end_index} : $last_idx;
        my $inside_idx = _first_zone_intersection($candles, $from, $to, $ob->{low}, $ob->{high});
        next unless defined $inside_idx;
        my $side = $ob->{ob_side} // (($ob->{type} // '') =~ /bear/ ? 'bearish' : 'bullish');
        push @$events, _event_base(
            id                => join('_', 'OB_INSIDE', $ob->{id}, _abs_i($inside_idx, $abs_offset)),
            type              => 'INSIDE_' . uc($side) . '_OB',
            symbol            => $symbol,
            timeframe         => $tf,
            start_index       => _abs_i($inside_idx, $abs_offset),
            start_time        => $candles->[$inside_idx]{time},
            confirmation_index=> _abs_i($inside_idx, $abs_offset),
            confirmation_time => $candles->[$inside_idx]{time},
            top               => $ob->{high},
            bottom            => $ob->{low},
            direction         => $side,
            strength          => 0.54,
            status            => 'historical',
            metadata          => {
                order_block_id => $ob->{id},
                ob_status      => $ob->{status},
                validation     => $ob->{validation},
            },
        );
    }
}

sub _append_support_resistance_events {
    my ($events, $symbol, $tf, $abs_offset, $candles, $atr_series, $levels) = @_;
    return unless $levels && @$levels && $candles && @$candles;
    my $last_idx = $#$candles;

    for my $lv (@$levels) {
        next unless defined $lv->{price} && defined $lv->{first_index};
        my $kind = uc($lv->{type} // 'LEVEL');
        my $tol = $lv->{tolerance} // _tol_at($atr_series, $candles, $lv->{last_index} // $lv->{first_index}, 0.25);
        my $status = $lv->{active} ? 'active' : 'invalidated';
        push @$events, _event_base(
            id                => $lv->{id},
            type              => $kind . '_LEVEL',
            symbol            => $symbol,
            timeframe         => $tf,
            start_index       => _abs_i($lv->{first_index}, $abs_offset),
            start_time        => $lv->{first_time},
            end_index         => defined $lv->{end_index} ? _abs_i($lv->{end_index}, $abs_offset) : _abs_i($last_idx, $abs_offset),
            end_time          => $lv->{end_time} // $candles->[$last_idx]{time},
            confirmation_index=> _abs_i($lv->{last_index}, $abs_offset),
            confirmation_time => $lv->{last_time},
            projection_end_index => defined $lv->{end_index} ? _abs_i($lv->{end_index}, $abs_offset) : _abs_i($last_idx, $abs_offset),
            price             => $lv->{price},
            top               => $lv->{price} + $tol,
            bottom            => $lv->{price} - $tol,
            direction         => ($lv->{type} // '') eq 'support' ? 'bullish' : 'bearish',
            strength          => _clamp01(0.35 + (($lv->{touches} // 1) * 0.08)),
            status            => $status,
            invalidation_time => $status eq 'invalidated' ? $lv->{end_time} : undef,
            metadata          => {
                touches          => $lv->{touches},
                pivot_ids        => $lv->{pivot_ids},
                current_relation => _price_relation_to_level($candles->[$last_idx]{close}, $lv->{price}, $tol),
                tolerance        => $tol,
            },
        );

        my $near_idx = _first_near_level_index($candles, $atr_series, $lv->{first_index}, $last_idx, $lv->{price}, 0.25);
        if (defined $near_idx) {
            push @$events, _level_context_event(
                $symbol, $tf, $abs_offset, $candles, $atr_series, $lv, $near_idx,
                'NEAR_' . $kind, 'neutral', 'historical', 0.25,
            );
        }
        if (defined $lv->{end_index}) {
            my $break_type = ($lv->{type} // '') eq 'support' ? 'BREAK_SUPPORT' : 'BREAK_RESISTANCE';
            push @$events, _level_context_event(
                $symbol, $tf, $abs_offset, $candles, $atr_series, $lv, $lv->{end_index},
                $break_type, ($lv->{type} // '') eq 'support' ? 'bearish' : 'bullish', 'invalidated', 0.25,
            );
        }
    }
}

sub _append_trendline_events {
    my ($events, $symbol, $tf, $abs_offset, $candles, $atr_series, $lines, $channels) = @_;
    return unless $candles && @$candles;
    my $last_idx = $#$candles;
    my %line_by_id = map { ($_->{id} // '') => $_ } @{ $lines // [] };

    for my $ln (@{ $lines // [] }) {
        next unless defined $ln->{start_index} && defined $ln->{y1};
        my $tol = _tol_at($atr_series, $candles, $last_idx, 0.20);
        my $line_price = _projected_line_price($ln, $last_idx);
        my $relation = _price_relation_to_level($candles->[$last_idx]{close}, $line_price, $tol);
        my $line_type = ($ln->{type} // '') eq 'support' ? 'TRENDLINE_SUPPORT' : 'TRENDLINE_RESISTANCE';
        push @$events, _event_base(
            id                => $ln->{id},
            type              => $line_type,
            symbol            => $symbol,
            timeframe         => $tf,
            start_index       => _abs_i($ln->{start_index}, $abs_offset),
            start_time        => $ln->{start_time},
            end_index         => _abs_i($last_idx, $abs_offset),
            end_time          => $candles->[$last_idx]{time},
            confirmation_index=> _abs_i($ln->{start_index}, $abs_offset),
            confirmation_time => $ln->{start_time},
            projection_end_index => _abs_i($last_idx, $abs_offset),
            price             => $line_price,
            direction         => $ln->{direction} // 'neutral',
            strength          => 0.44,
            status            => 'active',
            metadata          => {
                anchor_a_id      => $ln->{anchor_a_id},
                anchor_b_id      => $ln->{anchor_b_id},
                current_relation => $relation,
                slope            => $ln->{slope},
                tolerance        => $tol,
            },
        );

        my $cross_idx = _first_line_break_index($candles, $ln, $ln->{start_index} + 1, $last_idx, $tol);
        next unless defined $cross_idx;
        my $c = $candles->[$cross_idx];
        my $lp = _projected_line_price($ln, $cross_idx);
        my $above = ($c->{close} // 0) > $lp;
        push @$events, _event_base(
            id                => join('_', 'TRENDLINE_CONTEXT', $ln->{id}, _abs_i($cross_idx, $abs_offset)),
            type              => $above ? 'ABOVE_TRENDLINE' : 'BELOW_TRENDLINE',
            symbol            => $symbol,
            timeframe         => $tf,
            start_index       => _abs_i($cross_idx, $abs_offset),
            start_time        => $c->{time},
            confirmation_index=> _abs_i($cross_idx, $abs_offset),
            confirmation_time => $c->{time},
            price             => $lp,
            direction         => $above ? 'bullish' : 'bearish',
            strength          => 0.48,
            status            => 'historical',
            metadata          => {
                trendline_id => $ln->{id},
                relation     => $above ? 'above' : 'below',
            },
        );
    }

    for my $ch (@{ $channels // [] }) {
        my $base = $line_by_id{ $ch->{source_line_id} // '' };
        next unless $base;
        my ($low, $high) = _channel_bounds_at($base, $ch, $last_idx);
        my $close = $candles->[$last_idx]{close};
        my $relation = $close > $high ? 'above'
                     : $close < $low  ? 'below'
                     :                  'inside';
        push @$events, _event_base(
            id                => $ch->{id},
            type              => 'CHANNEL',
            symbol            => $symbol,
            timeframe         => $tf,
            start_index       => _abs_i($ch->{start_index}, $abs_offset),
            start_time        => $ch->{start_time},
            end_index         => _abs_i($last_idx, $abs_offset),
            end_time          => $candles->[$last_idx]{time},
            confirmation_index=> _abs_i($ch->{start_index}, $abs_offset),
            confirmation_time => $ch->{start_time},
            projection_end_index => _abs_i($last_idx, $abs_offset),
            top               => $high,
            bottom            => $low,
            direction         => $ch->{direction} // 'neutral',
            strength          => 0.42,
            status            => 'active',
            metadata          => {
                source_line_id    => $ch->{source_line_id},
                current_relation  => $relation,
            },
        );

        my $ctx = _first_channel_context($candles, $base, $ch, $ch->{start_index} + 1, $last_idx);
        next unless $ctx;
        push @$events, _event_base(
            id                => join('_', 'CHANNEL_CONTEXT', $ch->{id}, _abs_i($ctx->{index}, $abs_offset)),
            type              => $ctx->{type},
            symbol            => $symbol,
            timeframe         => $tf,
            start_index       => _abs_i($ctx->{index}, $abs_offset),
            start_time        => $candles->[$ctx->{index}]{time},
            confirmation_index=> _abs_i($ctx->{index}, $abs_offset),
            confirmation_time => $candles->[$ctx->{index}]{time},
            top               => $ctx->{top},
            bottom            => $ctx->{bottom},
            direction         => $ctx->{direction},
            strength          => 0.48,
            status            => 'historical',
            metadata          => {
                channel_id => $ch->{id},
                relation   => $ctx->{relation},
            },
        );
    }
}

sub _append_daily_level_events {
    my ($events, $symbol, $tf, $abs_offset, $candles, $atr_series, $levels) = @_;
    return unless $levels && @$levels && $candles && @$candles;
    my %by_day;
    for my $lv (@$levels) {
        next unless defined $lv->{daily_time};
        push @{ $by_day{ $lv->{daily_time} } }, $lv;
    }

    for my $day (sort keys %by_day) {
        my @levels = @{ $by_day{$day} };
        my %zone = map { ($_->{zone} // '') => $_ } @levels;
        for my $lv (@levels) {
            push @$events, _event_base(
                id                => $lv->{id},
                type              => uc($lv->{type}),
                symbol            => $symbol,
                timeframe         => $tf,
                source_timeframe  => 'D',
                start_index       => _abs_i($lv->{start_index}, $abs_offset),
                start_time        => $lv->{start_time},
                end_index         => _abs_i($lv->{end_index}, $abs_offset),
                end_time          => $lv->{end_time},
                confirmation_index=> _abs_i($lv->{start_index}, $abs_offset),
                confirmation_time => $lv->{start_time},
                projection_end_index => _abs_i($lv->{end_index}, $abs_offset),
                price             => $lv->{price},
                direction         => 'neutral',
                strength          => $lv->{near} ? 0.50 : 0.32,
                status            => 'active',
                metadata          => {
                    daily_time => $lv->{daily_time},
                    label      => $lv->{label},
                    zone       => $lv->{zone},
                    near       => $lv->{near} ? 1 : 0,
                },
            );
        }

        next unless $zone{wick_high} && $zone{wick_low} && $zone{body_high} && $zone{body_low};
        _append_daily_context_events($events, $symbol, $tf, $abs_offset, $candles, $atr_series, \%zone);
    }
}

sub _append_daily_context_events {
    my ($events, $symbol, $tf, $abs_offset, $candles, $atr_series, $zone) = @_;
    my $start = $zone->{wick_high}{start_index};
    my $end   = $zone->{wick_high}{end_index};
    return unless defined $start && defined $end;
    $start = 0 if $start < 0;
    $end = $#$candles if $end > $#$candles;

    my $high = $zone->{wick_high}{price};
    my $low  = $zone->{wick_low}{price};
    my $body_high = $zone->{body_high}{price};
    my $body_low  = $zone->{body_low}{price};
    return unless defined $high && defined $low && defined $body_high && defined $body_low;

    my %emitted;
    for my $i ($start .. $end) {
        my $c = $candles->[$i];
        my $atr = _atr_local($atr_series, $candles, $i);
        my $tol = $atr > 0 ? $atr * 0.25 : 0.01;
        my @ctx;

        push @ctx, ['ABOVE_DAILY_HIGH', 'bullish', $high, $high, $high]
            if ($c->{close} // 0) > $high + $tol;
        push @ctx, ['BELOW_DAILY_LOW', 'bearish', $low, $low, $low]
            if ($c->{close} // 0) < $low - $tol;
        push @ctx, ['INSIDE_DAILY_BODY', 'neutral', ($body_high + $body_low) / 2, $body_high, $body_low]
            if ($c->{close} // 0) <= $body_high && ($c->{close} // 0) >= $body_low;
        push @ctx, ['NEAR_DAILY_BODY', 'neutral', ($body_high + $body_low) / 2, $body_high, $body_low]
            if abs(($c->{close} // 0) - $body_high) <= $tol || abs(($c->{close} // 0) - $body_low) <= $tol;
        push @ctx, ['INSIDE_UPPER_WICK', 'bearish', ($high + $body_high) / 2, $high, $body_high]
            if ($c->{high} // 0) >= $body_high && ($c->{low} // 0) <= $high && ($c->{close} // 0) > $body_high;
        push @ctx, ['INSIDE_LOWER_WICK', 'bullish', ($body_low + $low) / 2, $body_low, $low]
            if ($c->{low} // 0) <= $body_low && ($c->{high} // 0) >= $low && ($c->{close} // 0) < $body_low;
        push @ctx, ['NEAR_DAILY_WICK', 'neutral', $high, $high, $low]
            if abs(($c->{close} // 0) - $high) <= $tol || abs(($c->{close} // 0) - $low) <= $tol;

        for my $ctx (@ctx) {
            my ($type, $dir, $price, $top, $bottom) = @$ctx;
            next if $emitted{$type}++;
            push @$events, _event_base(
                id                => join('_', $type, $zone->{wick_high}{daily_time}, _abs_i($i, $abs_offset)),
                type              => $type,
                symbol            => $symbol,
                timeframe         => $tf,
                source_timeframe  => 'D',
                start_index       => _abs_i($i, $abs_offset),
                start_time        => $c->{time},
                confirmation_index=> _abs_i($i, $abs_offset),
                confirmation_time => $c->{time},
                price             => $price,
                top               => $top,
                bottom            => $bottom,
                direction         => $dir,
                strength          => 0.45,
                status            => 'historical',
                metadata          => {
                    daily_time => $zone->{wick_high}{daily_time},
                    daily_high => $high,
                    daily_low  => $low,
                    body_high  => $body_high,
                    body_low   => $body_low,
                },
            );
        }
    }
}

sub _level_context_event {
    my ($symbol, $tf, $abs_offset, $candles, $atr_series, $lv, $idx, $type, $dir, $status, $tol_factor) = @_;
    return undef unless defined $idx && $candles && $idx >= 0 && $idx <= $#$candles;
    my $tol = $lv->{tolerance} // _tol_at($atr_series, $candles, $idx, $tol_factor // 0.20);
    return _event_base(
        id                => join('_', $type, $lv->{id}, _abs_i($idx, $abs_offset)),
        type              => $type,
        symbol            => $symbol,
        timeframe         => $tf,
        source_timeframe  => $lv->{source_timeframe},
        start_index       => _abs_i($idx, $abs_offset),
        start_time        => $candles->[$idx]{time},
        confirmation_index=> _abs_i($idx, $abs_offset),
        confirmation_time => $candles->[$idx]{time},
        price             => $lv->{price},
        top               => $lv->{price} + $tol,
        bottom            => $lv->{price} - $tol,
        direction         => $dir,
        strength          => 0.44,
        status            => $status,
        related_level_id  => $lv->{id},
        metadata          => {
            level_type => $lv->{type},
            relation   => _candle_relation_to_level($candles->[$idx], $lv->{price}, $tol),
            tolerance  => $tol,
            scope      => $lv->{internal_or_external},
        },
    );
}

sub _first_near_level_index {
    my ($candles, $atr_series, $from, $to, $price, $factor) = @_;
    return undef unless $candles && @$candles && defined $price;
    $from //= 0;
    $to //= $#$candles;
    $from = 0 if $from < 0;
    $to = $#$candles if $to > $#$candles;
    return undef if $from > $to;
    for my $i ($from .. $to) {
        my $tol = _tol_at($atr_series, $candles, $i, $factor // 0.20);
        my $c = $candles->[$i];
        return $i if abs(($c->{close} // 0) - $price) <= $tol;
        return $i if ($c->{low} // 0) <= $price && ($c->{high} // 0) >= $price;
    }
    return undef;
}

sub _first_break_level_index {
    my ($candles, $from, $to, $price, $tol, $type) = @_;
    return undef unless $candles && @$candles && defined $price;
    $from //= 0;
    $to //= $#$candles;
    $from = 0 if $from < 0;
    $to = $#$candles if $to > $#$candles;
    return undef if $from > $to;
    my $is_high = ($type // '') =~ /^(EQH|BSL|resistance)$/;
    for my $i ($from .. $to) {
        my $close = $candles->[$i]{close} // 0;
        return $i if $is_high && $close > $price + ($tol // 0);
        return $i if !$is_high && $close < $price - ($tol // 0);
    }
    return undef;
}

sub _first_zone_intersection {
    my ($candles, $from, $to, $low, $high) = @_;
    return undef unless $candles && @$candles;
    $from = 0 if !defined($from) || $from < 0;
    $to = $#$candles if !defined($to) || $to > $#$candles;
    return undef if $from > $to;
    for my $i ($from .. $to) {
        my $c = $candles->[$i];
        return $i if ($c->{low} // 0) <= $high && ($c->{high} // 0) >= $low;
    }
    return undef;
}

sub _nearest_liquidity_target {
    my ($levels, $idx, $c, $atr, $bullish) = @_;
    my $best;
    for my $lv (@{ $levels // [] }) {
        next unless defined $lv->{price} && _level_active_at($lv, $idx);
        my $type = $lv->{type} // '';
        next if $bullish && $type !~ /^(BSL|EQH)$/;
        next if !$bullish && $type !~ /^(SSL|EQL)$/;
        my $price = $lv->{price};
        my $close = $c->{close} // 0;
        my $open  = $c->{open} // 0;
        next if $bullish && $price <= $close;
        next if !$bullish && $price >= $close;
        my $dist_close = abs($price - $close);
        my $dist_open  = abs($price - $open);
        next unless $dist_close < $dist_open;
        next if $atr > 0 && $dist_close > $atr * 8;
        if (!$best || $dist_close < $best->{_dist}) {
            my %copy = %$lv;
            $copy{_dist} = $dist_close;
            $best = \%copy;
        }
    }
    return $best;
}

sub _level_active_at {
    my ($lv, $idx) = @_;
    return 0 unless defined $lv->{start_index} && $lv->{start_index} <= $idx;
    return 0 if defined $lv->{end_index} && $lv->{end_index} < $idx;
    return 1;
}

sub _first_line_break_index {
    my ($candles, $line, $from, $to, $tol) = @_;
    return undef unless $candles && @$candles && $line;
    $from = 0 if !defined($from) || $from < 0;
    $to = $#$candles if !defined($to) || $to > $#$candles;
    return undef if $from > $to;
    my $line_type = $line->{type} // '';
    for my $i ($from .. $to) {
        my $price = _projected_line_price($line, $i);
        my $close = $candles->[$i]{close} // 0;
        return $i if $line_type eq 'support' && $close < $price - ($tol // 0);
        return $i if $line_type eq 'resistance' && $close > $price + ($tol // 0);
    }
    return undef;
}

sub _first_channel_context {
    my ($candles, $base, $channel, $from, $to) = @_;
    return undef unless $candles && @$candles && $base && $channel;
    $from = 0 if !defined($from) || $from < 0;
    $to = $#$candles if !defined($to) || $to > $#$candles;
    return undef if $from > $to;

    for my $i ($from .. $to) {
        my ($low, $high) = _channel_bounds_at($base, $channel, $i);
        my $close = $candles->[$i]{close} // 0;
        if ($close > $high) {
            return { index => $i, type => 'BREAKOUT_CHANNEL_UP', relation => 'above', direction => 'bullish', top => $high, bottom => $low };
        }
        if ($close < $low) {
            return { index => $i, type => 'BREAKOUT_CHANNEL_DOWN', relation => 'below', direction => 'bearish', top => $high, bottom => $low };
        }
        return { index => $i, type => 'INSIDE_CHANNEL', relation => 'inside', direction => 'neutral', top => $high, bottom => $low };
    }
    return undef;
}

sub _channel_bounds_at {
    my ($base, $channel, $idx) = @_;
    my $a = _projected_line_price($base, $idx);
    my $b = _projected_line_price($channel, $idx);
    return $a <= $b ? ($a, $b) : ($b, $a);
}

sub _projected_line_price {
    my ($line, $idx) = @_;
    return undef unless $line && defined $line->{y1};
    return $line->{y1} + (($line->{slope} // 0) * ($idx - ($line->{start_index} // 0)));
}

sub _candle_relation_to_level {
    my ($c, $price, $tol) = @_;
    return 'unknown' unless $c && defined $price;
    return 'touching' if ($c->{low} // 0) <= $price && ($c->{high} // 0) >= $price;
    return _price_relation_to_level($c->{close}, $price, $tol);
}

sub _price_relation_to_level {
    my ($close, $price, $tol) = @_;
    return 'unknown' unless defined $close && defined $price;
    $tol //= 0;
    return 'near' if abs($close - $price) <= $tol;
    return $close > $price ? 'above' : 'below';
}

sub _tol_at {
    my ($atr_series, $candles, $idx, $factor) = @_;
    my $atr = _atr_local($atr_series, $candles, $idx);
    return $atr > 0 ? $atr * ($factor // 0.20) : 0.01;
}

sub _atr_local {
    my ($atr_series, $candles, $idx) = @_;
    return $atr_series->[$idx] + 0
        if $atr_series && defined $idx && defined $atr_series->[$idx] && $atr_series->[$idx] > 0;
    return 0 unless $candles && @$candles && defined $idx && $idx >= 0 && $idx <= $#$candles;
    my $from = $idx - 13;
    $from = 0 if $from < 0;
    my ($sum, $cnt) = (0, 0);
    for my $i ($from .. $idx) {
        next unless $candles->[$i];
        $sum += (($candles->[$i]{high} // 0) - ($candles->[$i]{low} // 0));
        $cnt++;
    }
    return $cnt ? $sum / $cnt : 0;
}

sub _ratio_id {
    my ($ratio) = @_;
    my $s = defined $ratio ? "$ratio" : 'unknown';
    $s =~ s/\./p/g;
    $s =~ s/[^0-9A-Za-z_]+/_/g;
    return $s;
}

sub _clamp01 {
    my ($v) = @_;
    $v = 0 if !defined($v) || $v < 0;
    $v = 1 if $v > 1;
    return sprintf('%.3f', $v) + 0;
}

sub _event_base {
    my (%e) = @_;
    $e{metadata} //= {};
    $e{strength} = defined $e{strength} ? sprintf('%.3f', $e{strength}) + 0 : 0;
    return \%e;
}

sub _event_strength {
    my ($vw) = @_;
    return 0.45 unless $vw;
    return $vw->{score} + 0 if defined $vw->{score};
    return $vw->{at_sweep}{score} + 0 if ref($vw->{at_sweep}) eq 'HASH' && defined $vw->{at_sweep}{score};
    return 0.45;
}

sub _abs_i {
    my ($idx, $offset) = @_;
    return undef unless defined $idx;
    return $idx + ($offset // 0);
}

sub _event_intersects_abs_range {
    my ($ev, $start, $end) = @_;
    my $x1 = $ev->{start_index};
    $x1 = $ev->{confirmation_index} if !defined $x1;
    return 0 unless defined $x1;
    my $x2 = $ev->{projection_end_index};
    $x2 = $ev->{end_index} if !defined $x2;
    $x2 = $x1 if !defined $x2;
    return $x1 <= $end && $x2 >= $start ? 1 : 0;
}

sub _filter_events_for_abs_range {
    my ($events, $start, $end, $limit) = @_;
    $limit //= $SMC_CONFIG->{maxEventsPerRequest} // 2000;
    my @out = grep { _event_intersects_abs_range($_, $start, $end) } @{ $events // [] };
    @out = sort {
        ($a->{start_index} // 0) <=> ($b->{start_index} // 0)
            || ($a->{type} // '') cmp ($b->{type} // '')
    } @out;
    my $truncated = @out > $limit ? 1 : 0;
    splice @out, $limit if $truncated;
    return (\@out, $truncated);
}

sub _shift_shape_indices {
    my ($shapes, $delta) = @_;
    return $shapes unless $delta;
    return [ map {
        my %s = %$_;
        $s{x1_index} += $delta if defined $s{x1_index};
        $s{x2_index} += $delta if defined $s{x2_index};
        \%s;
    } @$shapes ];
}

sub _volume_sources {
    my $data = $market->get_data;
    return {
        '1m'  => $data->{'1m'}  // [],
        '5m'  => $data->{'5m'}  // [],
        '15m' => $data->{'15m'} // [],
    };
}

sub _daily_candles_until {
    my ($cutoff_time, $current_tf) = @_;
    return [] if ($current_tf // '') eq 'D' || ($current_tf // '') eq 'W';
    return [] unless defined $cutoff_time;

    _build_market_cache_for('D');
    my $daily = $CACHE{'D'}{candles} // [];
    return [] unless @$daily;

    my $max = _closed_htf_max_index($daily, 'D', $cutoff_time);
    return [] if $max < 0;
    return [ @$daily[0 .. $max] ];
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
    require Time::Local;
    my ($Y, $Mo, $D, $h, $mi) = ($1+0, $2+0, $3+0, $4+0, $5+0);
    my $epoch = Time::Local::timegm(0, $mi, $h, $D, $Mo - 1, $Y - 1900);
    $epoch += ($minutes || 1) * 60;
    my @g = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:00', $g[5]+1900, $g[4]+1, $g[3], $g[2], $g[1]);
}

sub _closed_htf_max_index {
    my ($candles, $htf, $cutoff_time) = @_;
    return -1 unless $candles && @$candles && defined $cutoff_time;
    my $minutes = _tf_minutes($htf);

    my $latest_closed_start = _add_minutes_iso($cutoff_time, -$minutes);
    my ($lo, $hi) = (0, scalar @$candles);
    while ($lo < $hi) {
        my $mid = int(($lo + $hi) / 2);
        if (($candles->[$mid]{time} // '') le $latest_closed_start) {
            $lo = $mid + 1;
        } else {
            $hi = $mid;
        }
    }
    return $lo - 1;
}

sub _fast_active_htf_levels {
    my ($candles, $atr_series, $max_idx, $htf) = @_;
    return [] unless $candles && @$candles && $max_idx >= 0;
    $max_idx = $#$candles if $max_idx > $#$candles;
    return [] if $max_idx < ($HTF_SWING_K * 2);

    my (@future_high, @future_low);
    for (my $i = $max_idx; $i >= 0; $i--) {
        my $h = $candles->[$i]{high};
        my $l = $candles->[$i]{low};
        if ($i == $max_idx) {
            $future_high[$i] = $h;
            $future_low[$i]  = $l;
        } else {
            $future_high[$i] = $h > $future_high[$i + 1] ? $h : $future_high[$i + 1];
            $future_low[$i]  = $l < $future_low[$i + 1]  ? $l : $future_low[$i + 1];
        }
    }

    my (@highs, @lows);
    for my $i ($HTF_SWING_K .. $max_idx) {
        last if $i + $HTF_SWING_K > $max_idx;

        my $is_high = 1;
        my $is_low  = 1;
        for my $j (1 .. $HTF_SWING_K) {
            if ($candles->[$i - $j]{high} >= $candles->[$i]{high}
             || $candles->[$i + $j]{high} >= $candles->[$i]{high}) {
                $is_high = 0;
            }
            if ($candles->[$i - $j]{low} <= $candles->[$i]{low}
             || $candles->[$i + $j]{low} <= $candles->[$i]{low}) {
                $is_low = 0;
            }
            last unless $is_high || $is_low;
        }

        push @highs, {
            index        => $i,
            price        => $candles->[$i]{high},
            confirmed_at => $i + $HTF_SWING_K,
        } if $is_high;
        push @lows, {
            index        => $i,
            price        => $candles->[$i]{low},
            confirmed_at => $i + $HTF_SWING_K,
        } if $is_low;
    }

    my @levels;
    for my $sh (@highs) {
        next unless _htf_level_is_active('BSL', $sh->{price}, $sh->{confirmed_at}, \@future_high, \@future_low);
        push @levels, _htf_level($htf, 'BSL', $sh->{price}, $sh->{confirmed_at}, $sh->{index}, $candles);
    }
    for my $sl (@lows) {
        next unless _htf_level_is_active('SSL', $sl->{price}, $sl->{confirmed_at}, \@future_high, \@future_low);
        push @levels, _htf_level($htf, 'SSL', $sl->{price}, $sl->{confirmed_at}, $sl->{index}, $candles);
    }

    _append_fast_equal_htf_levels(\@levels, \@highs, 'EQH', $candles, $atr_series, $htf, \@future_high, \@future_low);
    _append_fast_equal_htf_levels(\@levels, \@lows,  'EQL', $candles, $atr_series, $htf, \@future_high, \@future_low);

    @levels = sort { ($b->{start_index} // 0) <=> ($a->{start_index} // 0) } @levels;
    splice @levels, $HTF_ACTIVE_MAX_LEVELS_PER_TF
        if @levels > $HTF_ACTIVE_MAX_LEVELS_PER_TF;
    return \@levels;
}

sub _append_fast_equal_htf_levels {
    my ($levels, $points, $type, $candles, $atr_series, $htf, $future_high, $future_low) = @_;
    return unless $points && @$points >= 2;

    for my $j (1 .. $#$points) {
        my $cur = $points->[$j];
        my $atr = $atr_series && defined $atr_series->[$cur->{index}]
            ? $atr_series->[$cur->{index}]
            : 0;
        next unless $atr > 0;

        my $tol = $atr * $HTF_EQ_FACTOR;
        my ($best, $best_dist);
        my $seen = 0;
        for (my $i = $j - 1; $i >= 0 && $seen < $HTF_EQ_LOOKBACK_SWINGS; $i--, $seen++) {
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
        next unless _htf_level_is_active($type, $price, $cur->{confirmed_at}, $future_high, $future_low);
        push @$levels, _htf_level($htf, $type, $price, $cur->{confirmed_at}, $best->{index} . '_' . $cur->{index}, $candles);
    }
}

sub _htf_level_is_active {
    my ($type, $price, $start_index, $future_high, $future_low) = @_;
    return 0 if !defined $start_index || $start_index < 0;

    if ($type eq 'BSL' || $type eq 'EQH') {
        return (($future_high->[$start_index] // $price) <= $price) ? 1 : 0;
    }
    return (($future_low->[$start_index] // $price) >= $price) ? 1 : 0;
}

sub _htf_level {
    my ($htf, $type, $price, $start_index, $key, $candles) = @_;
    return {
        id          => sprintf('HTF_%s_%s_%s', $htf, $type, $key),
        type        => $type,
        timeframe   => $htf,
        source_timeframe => $htf,
        price       => $price + 0,
        start_index => $start_index,
        start_time  => $candles && defined $start_index && $start_index <= $#$candles
                       ? $candles->[$start_index]{time} : undef,
        pivot_time  => $candles && defined $key && $key =~ /^\d+$/ && $key <= $#$candles
                       ? $candles->[$key]{time} : undef,
        active      => 1,
    };
}

sub _build_htf_liquidity_shapes_for {
    my ($tf, $win_start, $win_end, $local_max) = @_;
    return [] unless exists $HTF_SOURCES{$tf};

    my $cache_key = join(':', $tf, $win_start, $win_end, $local_max);
    return $HTF_LIQUIDITY_SHAPE_CACHE{$cache_key}
        if exists $HTF_LIQUIDITY_SHAPE_CACHE{$cache_key};

    _build_market_cache_for($tf);
    my $base_cache = $CACHE{$tf};
    return [] unless $base_cache && $base_cache->{candles} && @{ $base_cache->{candles} };

    my $visible_end = $base_cache->{candles}[$win_end]{time};
    my $visible_start = $base_cache->{candles}[$win_start]{time};
    my $cutoff_time = _add_minutes_iso($visible_end, _tf_minutes($tf));
    my @out;

    for my $htf (@{ $HTF_SOURCES{$tf} // [] }) {
        _build_market_cache_for($htf);
        my $hc = $CACHE{$htf};
        next unless $hc && $hc->{candles} && @{ $hc->{candles} };

        my $htf_max = _closed_htf_max_index($hc->{candles}, $htf, $cutoff_time);
        next if $htf_max < 0;

        # Para HTF solo necesitamos lineas de liquidez activas. Evitamos el
        # indicador completo (volumen/eventos/estado) en la ruta interactiva.
        my $levels = _fast_active_htf_levels($hc->{candles}, $hc->{atr}, $htf_max, $htf);
        for my $lv (@$levels) {
            my $role = lc($lv->{type} // '');
            next unless $role =~ /^(bsl|ssl|eqh|eql)$/;
            my $id = $lv->{id};
            push @out, {
                id                   => $id,
                source_type          => 'liquidity',
                source_id            => $lv->{id},
                kind                 => 'line',
                timeframe            => $htf,
                source_timeframe      => $htf,
                htf_source           => 1,
                internal_or_external => 'external',
                x1_index             => 0,
                x2_index             => $local_max,
                x1_abs_index         => $win_start,
                x2_abs_index         => $win_end,
                x1_time              => $visible_start,
                x2_time              => $visible_end,
                y1_price             => $lv->{price},
                y2_price             => $lv->{price},
                color_role           => $role,
                line_style           => 'solid',
                opacity              => 0.48,
                visible_by_default   => 1,
            };
            push @out, {
                id                   => "${id}_LBL",
                source_type          => 'liquidity',
                source_id            => $lv->{id},
                kind                 => 'label',
                timeframe            => $htf,
                source_timeframe      => $htf,
                htf_source           => 1,
                internal_or_external => 'external',
                x1_index             => $local_max,
                x2_index             => $local_max,
                x1_abs_index         => $win_end,
                x2_abs_index         => $win_end,
                x1_time              => $visible_end,
                x2_time              => $visible_end,
                y1_price             => $lv->{price},
                y2_price             => $lv->{price},
                text                 => uc($lv->{type}) . " $htf",
                color_role           => $role,
                line_style           => 'solid',
                opacity              => 0.70,
                visible_by_default   => 1,
            };
        }
    }

    $HTF_LIQUIDITY_SHAPE_CACHE{$cache_key} = \@out;
    return \@out;
}

sub _build_htf_liquidity_events_for {
    my ($symbol, $tf, $win_start, $win_end) = @_;
    return [] unless exists $HTF_SOURCES{$tf};

    _build_market_cache_for($tf);
    my $base_cache = $CACHE{$tf};
    return [] unless $base_cache && $base_cache->{candles} && @{ $base_cache->{candles} };

    my $visible_end = $base_cache->{candles}[$win_end]{time};
    my $visible_start = $base_cache->{candles}[$win_start]{time};
    my $cutoff_time = _add_minutes_iso($visible_end, _tf_minutes($tf));
    my @out;

    for my $htf (@{ $HTF_SOURCES{$tf} // [] }) {
        _build_market_cache_for($htf);
        my $hc = $CACHE{$htf};
        next unless $hc && $hc->{candles} && @{ $hc->{candles} };

        my $htf_max = _closed_htf_max_index($hc->{candles}, $htf, $cutoff_time);
        next if $htf_max < 0;

        my $levels = _fast_active_htf_levels($hc->{candles}, $hc->{atr}, $htf_max, $htf);
        for my $lv (@$levels) {
            my $type = uc($lv->{type} // 'LEVEL');
            my $dir = ($type eq 'BSL' || $type eq 'EQH') ? 'bullish' : 'bearish';
            push @out, _event_base(
                id                => $lv->{id},
                type              => "HTF_$type",
                symbol            => $symbol,
                timeframe         => $tf,
                source_timeframe  => $htf,
                start_time        => $lv->{start_time} // $visible_start,
                end_time          => $visible_end,
                price             => $lv->{price},
                direction         => $dir,
                strength          => 0.70,
                status            => 'active',
                metadata          => {
                    source_index      => $lv->{start_index},
                    source_timeframe  => $htf,
                    projected_from    => $visible_start,
                    projected_to      => $visible_end,
                    scope             => 'external',
                },
                start_index       => $win_start,
                end_index         => $win_end,
                projection_end_index => $win_end,
            );
        }
    }

    return \@out;
}

sub _build_previous_high_low_shapes_for {
    my ($tf, $win_start, $win_end, $local_max) = @_;
    return [] unless $SMC_CONFIG->{showPreviousHighLow};

    _build_market_cache_for($tf);
    my $base = $CACHE{$tf};
    return [] unless $base && $base->{candles} && @{ $base->{candles} };

    my $visible_start = $base->{candles}[$win_start]{time};
    my $visible_end   = $base->{candles}[$win_end]{time};
    my $cutoff_time   = _add_minutes_iso($visible_end, _tf_minutes($tf));

    my @levels = _previous_high_low_levels($cutoff_time);
    my @out;
    for my $lv (@levels) {
        my $id = "PHL_$lv->{type}_$lv->{period_time}";
        push @out, {
            id              => $id,
            source_type     => 'previous_high_low',
            source_id       => $id,
            kind            => 'line',
            timeframe       => $tf,
            source_timeframe=> $lv->{source_timeframe},
            x1_index        => 0,
            x2_index        => $local_max,
            x1_abs_index    => $win_start,
            x2_abs_index    => $win_end,
            x1_time         => $visible_start,
            x2_time         => $visible_end,
            y1_price        => $lv->{price},
            y2_price        => $lv->{price},
            color_role      => lc($lv->{type}),
            line_style      => 'dotted',
            opacity         => $lv->{source_timeframe} eq 'M' ? 0.42 : 0.52,
            visible_by_default => 1,
        };
        push @out, {
            id              => "${id}_LBL",
            source_type     => 'previous_high_low',
            source_id       => $id,
            kind            => 'label',
            timeframe       => $tf,
            source_timeframe=> $lv->{source_timeframe},
            x1_index        => $local_max,
            x2_index        => $local_max,
            x1_abs_index    => $win_end,
            x2_abs_index    => $win_end,
            x1_time         => $visible_end,
            x2_time         => $visible_end,
            y1_price        => $lv->{price},
            y2_price        => $lv->{price},
            text            => $lv->{label},
            color_role      => lc($lv->{type}),
            line_style      => 'solid',
            opacity         => 0.72,
            visible_by_default => 1,
        };
    }

    return \@out;
}

sub _build_previous_high_low_events_for {
    my ($symbol, $tf, $win_start, $win_end) = @_;
    return [] unless $SMC_CONFIG->{showPreviousHighLow};

    _build_market_cache_for($tf);
    my $base = $CACHE{$tf};
    return [] unless $base && $base->{candles} && @{ $base->{candles} };

    my $visible_start = $base->{candles}[$win_start]{time};
    my $visible_end   = $base->{candles}[$win_end]{time};
    my $cutoff_time   = _add_minutes_iso($visible_end, _tf_minutes($tf));
    my @levels = _previous_high_low_levels($cutoff_time);

    my @events;
    for my $lv (@levels) {
        push @events, _event_base(
            id               => "PHL_$lv->{type}_$lv->{period_time}",
            type             => $lv->{type},
            symbol           => $symbol,
            timeframe        => $tf,
            source_timeframe => $lv->{source_timeframe},
            start_index      => $win_start,
            start_time       => $visible_start,
            end_index        => $win_end,
            end_time         => $visible_end,
            confirmation_time=> $lv->{period_time},
            projection_end_index => $win_end,
            price            => $lv->{price},
            direction        => $lv->{direction},
            strength         => $lv->{source_timeframe} eq 'M' ? 0.70 : 0.62,
            status           => 'active',
            metadata         => {
                label       => $lv->{label},
                period_time => $lv->{period_time},
                source      => 'previous_high_low',
            },
        );
    }

    return \@events;
}

sub _previous_high_low_levels {
    my ($cutoff_time) = @_;
    my @levels;

    _build_market_cache_for('D');
    my $daily = $CACHE{'D'}{candles} // [];
    if ($daily && @$daily) {
        my $d_idx = _closed_htf_max_index($daily, 'D', $cutoff_time);
        if ($d_idx >= 0) {
            my $d = $daily->[$d_idx];
            push @levels, _prev_level('PDH', 'PDH', 'D', $d->{time}, $d->{high}, 'bearish');
            push @levels, _prev_level('PDL', 'PDL', 'D', $d->{time}, $d->{low},  'bullish');
        }

        my $m = _previous_month_level($daily, $cutoff_time);
        if ($m) {
            push @levels, _prev_level('PMH', 'PMH', 'M', $m->{time}, $m->{high}, 'bearish');
            push @levels, _prev_level('PML', 'PML', 'M', $m->{time}, $m->{low},  'bullish');
        }
    }

    _build_market_cache_for('W');
    my $weekly = $CACHE{'W'}{candles} // [];
    if ($weekly && @$weekly) {
        my $w_idx = _closed_htf_max_index($weekly, 'W', $cutoff_time);
        if ($w_idx >= 0) {
            my $w = $weekly->[$w_idx];
            push @levels, _prev_level('PWH', 'PWH', 'W', $w->{time}, $w->{high}, 'bearish');
            push @levels, _prev_level('PWL', 'PWL', 'W', $w->{time}, $w->{low},  'bullish');
        }
    }

    return @levels;
}

sub _prev_level {
    my ($type, $label, $source_tf, $period_time, $price, $direction) = @_;
    return {
        type             => $type,
        label            => $label,
        source_timeframe => $source_tf,
        period_time      => $period_time,
        price            => $price + 0,
        direction        => $direction,
    };
}

sub _previous_month_level {
    my ($daily, $cutoff_time) = @_;
    return undef unless $daily && @$daily && defined $cutoff_time;
    my $cur_month = substr($cutoff_time, 0, 7);
    my %months;

    for my $d (@$daily) {
        my $time = $d->{time};
        next unless defined $time;
        last if $time ge $cutoff_time;
        my $month = substr($time, 0, 7);
        next if $month ge $cur_month;
        if (!$months{$month}) {
            $months{$month} = {
                time => "$month-01T00:00:00",
                high => $d->{high},
                low  => $d->{low},
            };
        }
        else {
            $months{$month}{high} = $d->{high} if $d->{high} > $months{$month}{high};
            $months{$month}{low}  = $d->{low}  if $d->{low}  < $months{$month}{low};
        }
    }

    my @months = sort keys %months;
    return undef unless @months;
    return $months{ $months[-1] };
}

sub _slow_overlay_allowed {
    my ($c, $cache) = @_;
    my $total = scalar @{ $cache->{candles} // [] };
    return 1 if $total <= $FULL_OVERLAY_MAX_CANDLES;
    return 1 if ($ENV{ALLOW_SLOW_OVERLAYS} // 0);
    return (($c->param('allow_slow') // 0) ? 1 : 0);
}

# ============================================================
#  Helper: calcula la ventana de indices para candles/overlays.
#  Devuelve (win_start_abs, win_end_abs, max_abs_idx, is_replay).
# ============================================================

sub _resolve_window {
    my ($cache, $replay_index, $start_p, $end_p, $limit) = @_;
    my $total     = scalar @{ $cache->{candles} };
    my $max_abs   = $total - 1;
    my $is_replay = 0;

    if (defined $replay_index && $replay_index =~ /^\d+$/) {
        my $ri = $replay_index + 0;
        if ($ri < $max_abs) { $max_abs = $ri; $is_replay = 1; }
    }

    my $win_end;
    if (defined $end_p) {
        $win_end = ($end_p + 0) <= $max_abs ? ($end_p + 0) : $max_abs;
    } else {
        $win_end = $max_abs;
    }

    my $win_start;
    if (defined $start_p) {
        $win_start = ($start_p + 0) >= 0 ? ($start_p + 0) : 0;
        $win_start = $win_end if $win_start > $win_end;
    } else {
        $win_start = $win_end - $limit + 1;
        $win_start = 0 if $win_start < 0;
    }

    return ($win_start, $win_end, $max_abs, $is_replay);
}

sub _resolve_event_window {
    my ($cache, $replay_index, $from_p, $to_p, $start_p, $end_p, $limit) = @_;
    my $total   = scalar @{ $cache->{candles} };
    my $max_abs = $total - 1;
    my $is_replay = 0;

    if (defined $replay_index && $replay_index =~ /^\d+$/) {
        my $ri = $replay_index + 0;
        if ($ri < $max_abs) { $max_abs = $ri; $is_replay = 1; }
    }

    my ($win_start, $win_end);
    if (defined $start_p || defined $end_p) {
        ($win_start, $win_end) = _resolve_window($cache, $replay_index, $start_p, $end_p, $limit);
        return ($win_start, $win_end, $max_abs, $is_replay);
    }

    if (defined $from_p) {
        $win_start = _range_param_to_abs_index($cache->{candles}, $from_p, 'lower');
    }
    if (defined $to_p) {
        $win_end = _range_param_to_abs_index($cache->{candles}, $to_p, 'upper');
    }

    $win_end = $max_abs unless defined $win_end;
    $win_end = $max_abs if $win_end > $max_abs;
    $win_start = $win_end - $limit + 1 unless defined $win_start;
    $win_start = 0 if $win_start < 0;
    $win_start = $win_end if $win_start > $win_end;

    return ($win_start, $win_end, $max_abs, $is_replay);
}

sub _range_param_to_abs_index {
    my ($candles, $value, $mode) = @_;
    return undef unless defined $value;
    return $value + 0 if $value =~ /^\d+$/;
    my @times = map { $_->{time} // '' } @$candles;
    return 0 unless @times;
    if (($mode // '') eq 'upper') {
        my $pos = _upper_bound_time(\@times, $value) - 1;
        $pos = 0 if $pos < 0;
        $pos = $#times if $pos > $#times;
        return $pos;
    }
    my $pos = _lower_bound_time(\@times, $value);
    $pos = $#times if $pos > $#times;
    return $pos;
}

sub _lower_bound_time {
    my ($times, $target) = @_;
    my ($lo, $hi) = (0, scalar @$times);
    while ($lo < $hi) {
        my $mid = int(($lo + $hi) / 2);
        if (($times->[$mid] // '') lt $target) {
            $lo = $mid + 1;
        } else {
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
        } else {
            $hi = $mid;
        }
    }
    return $lo;
}

sub _build_smc_events_for {
    my ($symbol, $tf, $win_start, $win_end, $limit) = @_;
    my $key = join(':', $symbol // 'DEFAULT', $tf, $win_start, $win_end, $OVERLAY_LOOKBACK, $limit // ($SMC_CONFIG->{maxEventsPerRequest} // 2000));
    return $SMC_EVENT_CACHE{$key} if exists $SMC_EVENT_CACHE{$key};

    my $t0 = [gettimeofday];
    my $fast = _build_window_overlay_for($tf, $win_start, $win_end);
    my @events = map {
        my %ev = %$_;
        $ev{symbol} = $symbol // 'DEFAULT';
        \%ev;
    } @{ $fast->{events} // [] };
    push @events, @{ _build_htf_liquidity_events_for($symbol, $tf, $win_start, $win_end) };
    push @events, @{ _build_previous_high_low_events_for($symbol, $tf, $win_start, $win_end) };

    my ($filtered, $truncated) = _filter_events_for_abs_range(\@events, $win_start, $win_end, $limit);
    my $result = {
        events        => $filtered,
        truncated     => $truncated ? \1 : \0,
        market_regime => $fast->{market_regime},
        stats         => {
            win_start => $win_start,
            win_end   => $win_end,
            elapsed_s => sprintf('%.3f', tv_interval($t0)),
            source_events => scalar @events,
            returned_events => scalar @$filtered,
        },
    };

    $SMC_EVENT_CACHE{$key} = $result;
    return $result;
}

# ============================================================
#  Rutas
# ============================================================

get '/' => sub { $_[0]->reply->static('index.html') };

# --- /api/info : metadatos sin forzar calculo de indicadores ---
get '/api/info' => sub {
    my $c = shift;
    my %counts;
    for my $tf (@TFS) {
        if (exists $CACHE{$tf}) {
            my $cache = $CACHE{$tf};
            $counts{$tf} = {
                cached     => \1,
                market     => $cache->{market_ready}   ? \1 : \0,
                overlays   => $cache->{overlays_ready} ? \1 : \0,
                candles    => scalar @{ $cache->{candles} },
                atr        => scalar @{ $cache->{atr} },
                liq_levels => scalar @{ $cache->{liq_levels}     // [] },
                liq_events => scalar @{ $cache->{liq_events}     // [] },
                pivots     => scalar @{ $cache->{smc_pivots}     // [] },
                structures => scalar @{ $cache->{smc_structures} // [] },
                fvgs       => scalar @{ $cache->{smc_fvgs}       // [] },
                premium_discount => scalar @{ $cache->{smc_premium_discount_zones} // [] },
                strategy_shapes => scalar @{ $cache->{strategy_shapes} // [] },
            };
        } else {
            $counts{$tf} = { cached => \0, market => \0, overlays => \0, candles => 0 };
        }
    }
    $c->render(json => {
        ok         => \1,
        period_atr => $PERIOD,
        timeframes => \@TFS,
        smc_config => $SMC_CONFIG,
        counts     => \%counts,
    });
};

# --- /api/candles : velas + ATR ventaneados (indices locales 0..N-1) ---
#
# Parametros:
#   tf           : timeframe (default "1m")
#   start        : indice absoluto de inicio de ventana (opcional)
#   end          : indice absoluto de fin de ventana (opcional)
#   limit        : max velas a devolver si no hay start/end (default 500)
#   replay_index : indice absoluto de corte para modo replay (opcional)
#
# Respuesta: indices normalizados al inicio de la ventana (0-based).
get '/api/candles' => sub {
    my $c            = shift;
    my $tf           = $c->param('tf') // '1m';
    my $replay_index = $c->param('replay_index');
    my $start_p      = $c->param('start');
    my $end_p        = $c->param('end');
    my $all          = ($c->param('all') // 0) ? 1 : 0;
    my $with_anchors = ($c->param('anchors') // 0) ? 1 : 0;
    my $limit        = ($c->param('limit') // $DEFAULT_LIMIT) + 0;
    $limit = $DEFAULT_LIMIT if $limit <= 0 || $limit > 10_000;

    unless (grep { $_ eq $tf } @TFS) {
        return $c->render(json => { error => "timeframe invalido: $tf" }, status => 400);
    }

    _build_market_cache_for($tf);
    my $cache = $CACHE{$tf};
    if ($all) {
        $start_p = 0;
        $end_p   = undef;
    }

    my ($win_start, $win_end, $max_abs, $is_replay) =
        _resolve_window($cache, $replay_index, $start_p, $end_p, $limit);

    my @candles_slice;
    for my $abs_i ($win_start .. $win_end) {
        my %candle = %{ $cache->{candles}[$abs_i] };
        $candle{abs_index} = $abs_i;
        push @candles_slice, \%candle;
    }
    my @atr_slice     = @{ $cache->{atr}     }[$win_start .. $win_end];
    my $local_max     = $win_end - $win_start;
    my $total         = scalar @{ $cache->{candles} };

    my $payload = {
        timeframe         => $tf,
        candles           => \@candles_slice,
        atr               => \@atr_slice,
        total             => $total,
        win_start         => $win_start,
        win_end           => $win_end,
        first_index       => 0,
        last_index        => $local_max,
        has_more_left     => $win_start > 0       ? \1 : \0,
        has_more_right    => $win_end < $max_abs  ? \1 : \0,
        max_visible_index => $local_max,
        replay            => {
            active => $is_replay ? \1 : \0,
            index  => $local_max,
        },
    };
    $payload->{anchors} = $cache->{anchors} if $with_anchors;

    $c->render(json => $payload);
};

# --- /api/indicators/smc/events : eventos normalizados por rango visible ---
#
# Parametros compatibles:
#   tf | timeframe : temporalidad
#   start/end      : indices absolutos
#   from/to        : timestamp ISO o indice absoluto
#   replay_index   : corte replay-safe
#   limit          : maximo de eventos devueltos
#   symbol         : etiqueta logica del instrumento (default DEFAULT)
get '/api/indicators/smc/events' => sub {
    my $c            = shift;
    my $symbol       = $c->param('symbol') // 'DEFAULT';
    my $tf           = $c->param('timeframe') // $c->param('tf') // '1m';
    my $replay_index = $c->param('replay_index');
    my $from_p       = $c->param('from');
    my $to_p         = $c->param('to');
    my $start_p      = $c->param('start');
    my $end_p        = $c->param('end');
    my $default_event_limit = $SMC_CONFIG->{maxEventsPerRequest} // 2000;
    my $limit        = ($c->param('limit') // $default_event_limit) + 0;
    $limit = $default_event_limit if $limit <= 0 || $limit > 5000;

    unless (grep { $_ eq $tf } @TFS) {
        return $c->render(json => { error => "timeframe invalido: $tf" }, status => 400);
    }

    _build_market_cache_for($tf);
    my $cache = $CACHE{$tf};
    my ($win_start, $win_end, $max_abs, $is_replay) =
        _resolve_event_window($cache, $replay_index, $from_p, $to_p, $start_p, $end_p, $DEFAULT_LIMIT);

    my $bundle = _build_smc_events_for($symbol, $tf, $win_start, $win_end, $limit);
    my $mr = $bundle->{market_regime} // {};

    return $c->render(json => {
        ok                => \1,
        symbol            => $symbol,
        timeframe         => $tf,
        visible_abs_range => { start => $win_start, end => $win_end },
        from              => $cache->{candles}[$win_start]{time},
        to                => $cache->{candles}[$win_end]{time},
        replay            => {
            active => $is_replay ? \1 : \0,
            index  => $win_end,
        },
        context_state => {
            state                   => $mr->{state} // 'UNKNOWN',
            previous_state          => $mr->{previous_state},
            reason                  => $mr->{reason},
            confidence_score        => $mr->{confidence_score},
            nearest_liquidity_id    => $mr->{nearest_liquidity_id},
            last_liquidity_event_id => $mr->{last_liquidity_event_id},
            last_structure_event_id => $mr->{last_structure_event_id},
            replay_safe             => \1,
        },
        events    => $bundle->{events},
        truncated => $bundle->{truncated},
        stats     => $bundle->{stats},
    });
};

# --- /api/overlays : SMC + Liquidity + MarketRegime ventaneados ---
#
# Parametros: mismos que /api/candles.
# Shapes devueltos con x1_index/x2_index normalizados a la ventana (0-based).
get '/api/overlays' => sub {
    my $c            = shift;
    my $tf           = $c->param('tf') // '1m';
    my $replay_index = $c->param('replay_index');
    my $start_p      = $c->param('start');
    my $end_p        = $c->param('end');
    my $debug        = ($c->param('debug') // 0) ? 1 : 0;
    my $full         = ($c->param('full')  // 0) ? 1 : 0;
    my $absolute     = ($c->param('absolute') // 0) ? 1 : 0;
    my $limit        = ($c->param('limit') // $DEFAULT_LIMIT) + 0;
    $limit = $DEFAULT_LIMIT if $limit <= 0 || $limit > 10_000;

    unless (grep { $_ eq $tf } @TFS) {
        return $c->render(json => { error => "timeframe invalido: $tf" }, status => 400);
    }

    _build_market_cache_for($tf);
    my $cache = $CACHE{$tf};

    my ($win_start, $win_end, $max_abs, $is_replay) =
        _resolve_window($cache, $replay_index, $start_p, $end_p, $limit);

    my $local_max = $win_end - $win_start;

    if (!$debug && !$full) {
        my $fast = _build_window_overlay_for($tf, $win_start, $win_end);
        my $mr = $fast->{market_regime};
        my $liquidity = { %{ $fast->{liquidity} } };
        my $smc       = { %{ $fast->{smc} } };
        my $strategy  = { %{ $fast->{strategy} // { overlay_shapes => [] } } };
        my $htf_shapes = _build_htf_liquidity_shapes_for($tf, $win_start, $win_end, $local_max);
        my $prev_hl_shapes = _build_previous_high_low_shapes_for($tf, $win_start, $win_end, $local_max);
        $liquidity->{overlay_shapes} = [ @{ $liquidity->{overlay_shapes} // [] }, @$htf_shapes ];
        $smc->{overlay_shapes} = [ @{ $smc->{overlay_shapes} // [] }, @$prev_hl_shapes ];
        if ($absolute) {
            $liquidity->{overlay_shapes} =
                _shift_shape_indices($liquidity->{overlay_shapes}, $win_start);
            $smc->{overlay_shapes} =
                _shift_shape_indices($smc->{overlay_shapes}, $win_start);
            $strategy->{overlay_shapes} =
                _shift_shape_indices($strategy->{overlay_shapes}, $win_start);
        }
        return $c->render(json => {
            timeframe         => $tf,
            visible_range     => { start => 0, end => $local_max },
            win_start         => $win_start,
            win_end           => $win_end,
            visible_abs_range => { start => $win_start, end => $win_end },
            max_visible_index => $local_max,
            partial           => \1,
            lookback          => $OVERLAY_LOOKBACK,
            replay            => {
                active => $is_replay ? \1 : \0,
                index  => $local_max,
            },
            market_regime => {
                state                   => $mr->{state},
                previous_state          => $mr->{previous_state},
                reason                  => $mr->{reason},
                confidence_score        => $mr->{confidence_score},
                nearest_liquidity_id    => $mr->{nearest_liquidity_id},
                last_liquidity_event_id => $mr->{last_liquidity_event_id},
                last_structure_event_id => $mr->{last_structure_event_id},
                replay_safe             => \1,
            },
            liquidity => $liquidity,
            smc       => $smc,
            strategy  => $strategy,
        });
    }

    unless (_slow_overlay_allowed($c, $cache)) {
        return $c->render(
            json => {
                error   => 'calculo full/debug demasiado costoso',
                detail  => "TF $tf tiene " . scalar(@{ $cache->{candles} }) .
                           " velas; usa la ruta ventaneada o agrega allow_slow=1",
                max_safe_candles => $FULL_OVERLAY_MAX_CANDLES,
            },
            status => 403,
        );
    }

    _build_overlay_cache_for($tf);
    $cache = $CACHE{$tf};

    # Regimen en la ultima vela visible
    my $regime_states = $cache->{regime_states};
    my $cur_regime    = ($regime_states && @$regime_states && $win_end < scalar @$regime_states)
                        ? $regime_states->[$win_end]
                        : { state => 'UNKNOWN', reason => 'fuera de rango', replay_safe => 1 };

    # Datos crudos: solo para inspeccion/debug; son grandes y no se usan para dibujar.
    my ($liq_levels, $liq_events, $pivots, $structures, $fvgs, $fib_sets, $pd_zones, $strategy_debug);
    if ($debug) {
        $liq_levels = _clip_array($cache->{liq_levels}, $win_end, 'start_index');
        $liq_events = _clip_array($cache->{liq_events}, $win_end, 'swept_index');
        $pivots     = _clip_array($cache->{smc_pivots},     $win_end, 'confirmed_at');
        $structures = _clip_array($cache->{smc_structures}, $win_end, 'break_index');
        $fvgs       = _clip_array($cache->{smc_fvgs},       $win_end, 'end_index');
        $fib_sets   = $cache->{smc_fib_sets};
        $pd_zones   = $cache->{smc_premium_discount_zones};
        $strategy_debug = $cache->{strategy};
    }

    # Shapes: filtrar al rango [win_start, win_end] y normalizar a 0-based.
    my $liq_shapes = _clip_shapes_window($cache->{liq_shapes}, $win_start, $win_end, 0, $cache->{candles});
    my $smc_shapes = _clip_shapes_window($cache->{smc_shapes}, $win_start, $win_end, 0, $cache->{candles});
    my $strategy_shapes = _clip_shapes_window($cache->{strategy_shapes} // [], $win_start, $win_end, 0, $cache->{candles});
    if ($absolute) {
        $liq_shapes = _shift_shape_indices($liq_shapes, $win_start);
        $smc_shapes = _shift_shape_indices($smc_shapes, $win_start);
        $strategy_shapes = _shift_shape_indices($strategy_shapes, $win_start);
    }

    # HTF: niveles activos de temporalidades superiores.
    # Se calculan tambien en la ruta normal, no solo debug/full, y se
    # recortan al ultimo HTF cerrado para evitar fuga de velas futuras.
    my $htf_shapes = _build_htf_liquidity_shapes_for($tf, $win_start, $win_end, $local_max);
    my $prev_hl_shapes = _build_previous_high_low_shapes_for($tf, $win_start, $win_end, $local_max);
    $prev_hl_shapes = _shift_shape_indices($prev_hl_shapes, $win_start) if $absolute;

    my $liquidity = {
        overlay_shapes => [@$liq_shapes, @$htf_shapes],
    };
    my $smc = {
        overlay_shapes => [@$smc_shapes, @$prev_hl_shapes],
    };
    my $strategy = {
        overlay_shapes => $strategy_shapes,
    };
    if ($debug) {
        $liquidity->{levels}     = $liq_levels;
        $liquidity->{events}     = $liq_events;
        $smc->{pivots}           = $pivots;
        $smc->{structures}       = $structures;
        $smc->{fvgs}             = $fvgs;
        $smc->{fib_sets}         = $fib_sets;
        $smc->{premium_discount_zones} = $pd_zones;
        $strategy->{data}        = $strategy_debug;
    }

    $c->render(json => {
        timeframe         => $tf,
        visible_range     => { start => 0, end => $local_max },
        win_start         => $win_start,
        win_end           => $win_end,
        visible_abs_range => { start => $win_start, end => $win_end },
        max_visible_index => $local_max,
        replay            => {
            active => $is_replay ? \1 : \0,
            index  => $local_max,
        },
        market_regime => {
            state                   => $cur_regime->{state},
            previous_state          => $cur_regime->{previous_state},
            reason                  => $cur_regime->{reason},
            confidence_score        => $cur_regime->{confidence_score},
            nearest_liquidity_id    => $cur_regime->{nearest_liquidity_id},
            last_liquidity_event_id => $cur_regime->{last_liquidity_event_id},
            last_structure_event_id => $cur_regime->{last_structure_event_id},
            replay_safe             => \1,
        },
        liquidity => $liquidity,
        smc       => $smc,
        strategy  => $strategy,
    });
};

app->start;
