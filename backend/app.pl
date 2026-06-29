#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin";

use Mojolicious::Lite;
use Time::HiRes qw(gettimeofday tv_interval);

use Market::MarketData;
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
my $PERIOD        = 14;
my $DEFAULT_LIMIT = 500;
my $OVERLAY_LOOKBACK = 750;
my $FULL_OVERLAY_MAX_CANDLES = 6_000;
my $HTF_ACTIVE_MAX_LEVELS_PER_TF = 32;
my $HTF_SWING_K = 3;
my $HTF_EQ_FACTOR = 0.10;
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

    my $result = {
        market_regime => $cur_regime,
        liquidity     => { overlay_shapes => $liq_shapes },
        smc           => { overlay_shapes => $smc_shapes },
        strategy      => { overlay_shapes => $strategy_shapes },
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
        push @levels, _htf_level($htf, 'BSL', $sh->{price}, $sh->{confirmed_at}, $sh->{index});
    }
    for my $sl (@lows) {
        next unless _htf_level_is_active('SSL', $sl->{price}, $sl->{confirmed_at}, \@future_high, \@future_low);
        push @levels, _htf_level($htf, 'SSL', $sl->{price}, $sl->{confirmed_at}, $sl->{index});
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
        push @$levels, _htf_level($htf, $type, $price, $cur->{confirmed_at}, $best->{index} . '_' . $cur->{index});
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
    my ($htf, $type, $price, $start_index, $key) = @_;
    return {
        id          => sprintf('HTF_%s_%s_%s', $htf, $type, $key),
        type        => $type,
        timeframe   => $htf,
        price       => $price + 0,
        start_index => $start_index,
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
        $liquidity->{overlay_shapes} = [ @{ $liquidity->{overlay_shapes} // [] }, @$htf_shapes ];
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
    my ($liq_levels, $liq_events, $pivots, $structures, $fvgs, $fib_sets, $strategy_debug);
    if ($debug) {
        $liq_levels = _clip_array($cache->{liq_levels}, $win_end, 'start_index');
        $liq_events = _clip_array($cache->{liq_events}, $win_end, 'swept_index');
        $pivots     = _clip_array($cache->{smc_pivots},     $win_end, 'confirmed_at');
        $structures = _clip_array($cache->{smc_structures}, $win_end, 'break_index');
        $fvgs       = _clip_array($cache->{smc_fvgs},       $win_end, 'end_index');
        $fib_sets   = $cache->{smc_fib_sets};
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

    my $liquidity = {
        overlay_shapes => [@$liq_shapes, @$htf_shapes],
    };
    my $smc = {
        overlay_shapes => $smc_shapes,
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
