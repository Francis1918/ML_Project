package Market::MarketData;

use strict;
use warnings;

# ============================================================
#  Market::MarketData
#  Responsabilidad UNICA: almacenar y organizar velas OHLCV.
#  No calcula indicadores ni dibuja nada.
# ============================================================

my %FACTOR = (
    '1m'  => 1,
    '5m'  => 5,
    '15m' => 15,
);

sub new {
    my ($class) = @_;
    my $self = {
        data => {
            '1m'  => [],
            '5m'  => [],
            '15m' => [],
        },
        timeframe => '1m',
    };
    bless $self, $class;
    return $self;
}

sub add_candle {
    my ($self, $candle) = @_;
    push @{ $self->{data}{'1m'} }, $candle;
    return;
}

sub build_tf_candles {
    my ($self, $tf) = @_;

    my $n    = $FACTOR{$tf};
    my $base = $self->{data}{'1m'};
    my @out;

    my ($cur_group, $cur_bucket);

    for my $c (@$base) {
        my $ts = $c->{time};
        my ($Y, $Mo, $D, $h, $mi) = $ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/;
        next unless defined $mi;

        # Alinear al inicio real del intervalo (ej: 5:02 → 5:00 para 5m)
        my $aligned_min = int($mi / $n) * $n;
        my $bucket = sprintf("%s-%s-%sT%02d:%02d:00", $Y, $Mo, $D, $h, $aligned_min);

        if (!defined $cur_bucket || $bucket ne $cur_bucket) {
            push @out, $cur_group if defined $cur_group;
            $cur_bucket = $bucket;
            $cur_group  = {
                time   => $bucket,
                open   => $c->{open},
                high   => $c->{high},
                low    => $c->{low},
                close  => $c->{close},
                volume => $c->{volume} // 0,
            };
        } else {
            $cur_group->{high}   = $c->{high} if $c->{high} > $cur_group->{high};
            $cur_group->{low}    = $c->{low}  if $c->{low}  < $cur_group->{low};
            $cur_group->{close}  = $c->{close};
            $cur_group->{volume} += $c->{volume} // 0;
        }
    }
    push @out, $cur_group if defined $cur_group;

    $self->{data}{$tf} = \@out;
    return;
}

sub build_timeframes {
    my ($self) = @_;
    $self->build_tf_candles('5m');
    $self->build_tf_candles('15m');
    return;
}

sub set_timeframe {
    my ($self, $tf) = @_;
    die "Timeframe invalido: $tf" unless exists $FACTOR{$tf};
    $self->{timeframe} = $tf;
    return;
}

sub _active_array {
    my ($self) = @_;
    return $self->{data}{ $self->{timeframe} };
}

sub size {
    my ($self) = @_;
    return scalar @{ $self->_active_array };
}

sub get_candle {
    my ($self, $index) = @_;
    return $self->_active_array->[$index];
}

sub last_index {
    my ($self) = @_;
    return $self->size - 1;
}

sub last_candle {
    my ($self) = @_;
    return $self->get_candle( $self->last_index );
}

sub get_data {
    my ($self) = @_;
    return $self->{data};
}

# --- get_slice ----------------------------------------------
sub get_slice {
    my ($self, $start, $end) = @_;
    my $arr  = $self->_active_array;
    my $last = $#$arr;
    return [] if $last < 0;

    $start = 0     if $start < 0;
    $end   = $last if $end > $last;
    return [] if $start > $end;

    return [ @{$arr}[ $start .. $end ] ];
}

# --- get_timestamp ------------------------------------------
sub get_timestamp {
    my ($self, $index) = @_;
    my $c = $self->get_candle($index);
    return defined $c ? $c->{time} : undef;
}

# --- merge_delta_row ----------------------------------------
sub merge_delta_row {
    my ($self, $row) = @_;
    my $base = $self->{data}{'1m'};

    if (@$base && $base->[-1]{time} eq $row->{time}) {
        $base->[-1] = { %$row };
    }
    else {
        push @$base, { %$row };
    }
    return;
}

# --- compute_time_anchors -----------------------------------
sub compute_time_anchors {
    my ($self) = @_;
    my $arr = $self->_active_array;
    my @anchors;

    my ($prev_hour, $prev_day) = (-1, '');
    for my $i (0 .. $#$arr) {
        my $ts = $arr->[$i]{time};
        my ($Y, $M, $D, $h) = $ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2})/;
        next unless defined $h;

        my $day = "$Y-$M-$D";
        if ($h != $prev_hour || $day ne $prev_day) {
            push @anchors, {
                index      => $i,
                time       => $ts,
                hour       => $h + 0,
                is_new_day => ($day ne $prev_day) ? 1 : 0,
            };
            $prev_hour = $h + 0;
            $prev_day  = $day;
        }
    }
    return \@anchors;
}

1;
