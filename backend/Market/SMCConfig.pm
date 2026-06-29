package Market::SMCConfig;

use strict;
use warnings;

sub defaults {
    return {
        version                    => 1,
        swingLookback              => 3,
        internalSwingLookback      => 3,
        atrPeriod                  => 14,
        equalHighLowAtrTolerance   => 0.10,
        displacementAtrMultiplier  => 1.05,
        fvgMinSizeAtrMultiplier    => 0,
        obMaxLookback              => 8,
        overlayLookback            => 750,
        maxEventsPerRequest        => 2000,
        maxHtfLevelsPerTimeframe   => 32,
        htfTimeframes              => [qw(5m 15m 1h 2h 4h D W)],
        showInternalStructure      => 1,
        showSwingStructure         => 1,
        showLiquidity              => 1,
        showHTFLiquidity           => 1,
        showFVG                    => 1,
        showOrderBlocks            => 1,
        showPremiumDiscount        => 1,
        showPreviousHighLow        => 1,
    };
}

1;
