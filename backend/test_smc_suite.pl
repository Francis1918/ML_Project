#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin";

use Test::More;

use Market::Indicators::Liquidity;
use Market::Indicators::SMC_Structures;
use Market::Indicators::Strategy_Builder;
use Market::SMCConfig;

sub c {
    my ($i, $o, $h, $l, $cl, $v) = @_;
    return {
        time   => sprintf('2026-06-29T00:%02d:00', $i),
        open   => $o,
        high   => $h,
        low    => $l,
        close  => $cl,
        volume => $v // 1000,
    };
}

sub atr {
    my ($candles, $v) = @_;
    return [ map { $v // 1 } @$candles ];
}

my $structure_candles = [
    c(0,  9.5, 10,  9,  9.5, 1000),
    c(1, 10.5, 11, 10, 10.5, 1000),
    c(2, 11.5, 12, 11, 11.5, 1000),
    c(3, 14.0, 15, 12, 14.0, 1000),
    c(4, 11.0, 12, 10, 10.8, 1000),
    c(5, 10.0, 11,  9,  9.5, 1000),
    c(6,  9.0, 10,  8,  8.5, 1000),
    c(7, 14.0, 16, 13, 16.0, 4000),
    c(8, 13.0, 14, 12, 12.8, 1000),
    c(9, 12.0, 13, 11, 11.8, 1000),
    c(10, 9.0,  9.5, 6.5, 6.6, 4000),
    c(11, 8.0,  9,  7,  8.5, 1000),
];

my $smc = Market::Indicators::SMC_Structures->compute(
    candles           => $structure_candles,
    atr_series        => atr($structure_candles, 1),
    max_visible_index => $#$structure_candles,
    timeframe         => '1m',
    liquidity_events  => [],
    config            => Market::SMCConfig->defaults,
);

ok(scalar(grep { $_->{kind} eq 'high' && $_->{label} eq 'HH' && defined $_->{confirmed_time} } @{ $smc->{pivots} }), 'detecta swing high confirmado');
ok(scalar(grep { $_->{kind} eq 'low'  && $_->{label} eq 'LL' && defined $_->{confirmed_time} } @{ $smc->{pivots} }), 'detecta swing low confirmado');
ok(scalar(grep { $_->{type} eq 'BOS' && $_->{direction} eq 'bullish' && defined $_->{confirmation_time} } @{ $smc->{structures} }), 'detecta BOS confirmado por cierre');
ok(scalar(grep { $_->{type} eq 'CHOCH' && $_->{direction} eq 'bearish' } @{ $smc->{structures} }), 'detecta CHoCH');
ok(scalar(grep { $_->{type} eq 'MSS' && $_->{direction} eq 'bearish' } @{ $smc->{structures} }), 'deriva MSS desde CHoCH confirmado');
ok(@{ $smc->{premium_discount_zones} } >= 1, 'genera Premium/Discount desde rango estructural');
ok(scalar(grep { ($_->{strength_class} // '') =~ /^(strong|weak)_(high|low)$/ } @{ $smc->{pivots} }), 'clasifica pivots strong/weak');
ok((Market::SMCConfig->defaults->{maxEventsPerRequest} // 0) > 0, 'config central expone maxEventsPerRequest');

my $fvg_candles = [
    c(0, 10.0, 10.0,  9.0,  9.5),
    c(1, 10.2, 10.8, 10.0, 10.6),
    c(2, 11.2, 12.0, 11.0, 11.8),
    c(3, 11.8, 12.2, 11.4, 12.0),
    c(4, 12.0, 12.4, 11.5, 12.1),
    c(5, 10.9, 11.3, 10.5, 10.8),
];
my $fvg_smc = Market::Indicators::SMC_Structures->compute(
    candles           => $fvg_candles,
    atr_series        => atr($fvg_candles, 1),
    max_visible_index => $#$fvg_candles,
    timeframe         => '1m',
    liquidity_events  => [],
);
ok(scalar(grep { $_->{direction} eq 'bullish' && $_->{status} eq 'mitigated' && defined $_->{mitigation_time} } @{ $fvg_smc->{fvgs} }), 'FVG bullish pasa a mitigated');

my $liq_candles = [
    c(0, 10, 10,   9,  9.5),
    c(1, 11, 11,  10, 10.5),
    c(2, 12, 12,  11, 11.5),
    c(3, 14, 15,  12, 14.5),
    c(4, 12, 12,  10, 10.8),
    c(5, 11, 11,   9,  9.8),
    c(6, 10, 10,   8,  9.0),
    c(7, 12, 14.8,10, 12.5),
    c(8, 14, 15.4,13, 14.8),
    c(9, 14, 14.5,12, 14.0),
    c(10,13, 13.5,11, 12.5),
    c(11,12, 12.5,10, 11.5),
    c(12,11, 11.5, 9, 10.5),
];
my $liq = Market::Indicators::Liquidity->compute(
    candles           => $liq_candles,
    atr_series        => atr($liq_candles, 10),
    max_visible_index => $#$liq_candles,
    timeframe         => '1m',
);
ok(scalar(grep { $_->{type} eq 'BSL' } @{ $liq->{levels} }), 'detecta BSL');
ok(scalar(grep { $_->{type} eq 'EQH' } @{ $liq->{levels} }), 'detecta EQH');
ok(scalar(grep { ($_->{classification} // '') =~ /GRAB|SWEEP|RUN/ } @{ $liq->{events} }), 'emite evento de sweep/grab/run');

my $strategy = Market::Indicators::Strategy_Builder->compute(
    candles           => $structure_candles,
    atr_series        => atr($structure_candles, 1),
    liquidity_levels  => [],
    liquidity_events  => [],
    structure_events  => $smc->{structures},
    pivots            => $smc->{pivots},
    max_visible_index => $#$structure_candles,
    timeframe         => '1m',
);
ok(scalar(grep { $_->{validation} && $_->{validation}{structure_event_id} } @{ $strategy->{order_blocks} }), 'Order Block exige validacion estructural');
ok(scalar(grep { ($_->{derived_from} // '') =~ /order_block|displacement|liquidity_reaction/ } @{ $strategy->{supply_zones} }), 'Supply zones conservan origen derivado');
ok(scalar(grep { ($_->{derived_from} // '') =~ /order_block|displacement|liquidity_reaction/ } @{ $strategy->{demand_zones} }), 'Demand zones conservan origen derivado');

done_testing();
