package Market::MarketData;

use strict;
use warnings;
use POSIX qw(mktime);

# ============================================================
#  Market::MarketData
#  Responsabilidad UNICA: almacenar y organizar velas OHLCV.
#  No calcula indicadores ni dibuja nada.
#
#  Temporalidades soportadas: 1m, 5m, 15m, 1h, 2h, 4h, D, W
#  Regla OHLCV:
#    Open   = open de la primera vela del bloque
#    High   = maximo de todos los high del bloque
#    Low    = minimo de todos los low del bloque
#    Close  = close de la ultima vela del bloque
#    Volume = suma de volumen del bloque
# ============================================================

my %FACTOR = (
    '1m'  => 1,
    '5m'  => 5,
    '15m' => 15,
    '1h'  => 60,
    '2h'  => 120,
    '4h'  => 240,
    'D'   => undef,   # bucket especial: por fecha
    'W'   => undef,   # bucket especial: por semana (lunes)
);

# Minutos de ventana para anchors de ejes de tiempo por TF
my %ANCHOR_SLOT = (
    '1m'  => 10,
    '5m'  => 20,
    '15m' => 60,
    '1h'  => 240,
    '2h'  => 480,
    '4h'  => 960,
);

sub new {
    my ($class) = @_;
    my $self = {
        data      => { map { $_ => [] } keys %FACTOR },
        timeframe => '1m',
    };
    bless $self, $class;
    return $self;
}

# ============================================================
#  Ingesta de velas 1m
# ============================================================

sub add_candle {
    my ($self, $candle) = @_;
    push @{ $self->{data}{'1m'} }, $candle;
    return;
}

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

# ============================================================
#  Construccion de temporalidades derivadas
# ============================================================

# Calcula el bucket temporal de una vela 1m para el TF dado.
# Retorna un string que identifica univocamente el bloque.
# Formato uniforme: "YYYY-MM-DDThh:mm:00"
sub _candle_bucket {
    my ($self, $tf, $c) = @_;
    my $ts = $c->{time};
    my ($Y, $Mo, $D, $h, $mi) = $ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/;
    return undef unless defined $mi;

    if ($tf eq 'D') {
        return "${Y}-${Mo}-${D}T00:00:00";
    }
    elsif ($tf eq 'W') {
        my $monday = _monday_of($Y + 0, $Mo + 0, $D + 0);
        return "${monday}T00:00:00";
    }
    else {
        my $n         = $FACTOR{$tf};
        my $total_min = $h * 60 + $mi;
        my $aligned   = int($total_min / $n) * $n;
        my $ah        = int($aligned / 60);
        my $am        = $aligned % 60;
        return sprintf("%s-%s-%sT%02d:%02d:00", $Y, $Mo, $D, $ah, $am);
    }
}

# Devuelve la fecha del lunes de la semana ISO que contiene (Y, M, D).
sub _monday_of {
    my ($Y, $M, $D) = @_;
    my $epoch = mktime(0, 0, 12, $D, $M - 1, $Y - 1900);
    my @lt    = localtime($epoch);
    my $wday  = $lt[6];                        # 0=Dom, 1=Lun, ..., 6=Sab
    my $back  = ($wday == 0) ? 6 : $wday - 1; # dias para retroceder al lunes
    my @mt    = localtime($epoch - $back * 86400);
    return sprintf("%04d-%02d-%02d", $mt[5] + 1900, $mt[4] + 1, $mt[3]);
}

# Agrega todas las velas 1m en bloques para el TF indicado.
# Siempre parte de 1m; no hace construccion en cascada.
sub build_tf_candles {
    my ($self, $tf) = @_;
    my $base = $self->{data}{'1m'};
    my @out;
    my ($cur_group, $cur_bucket);

    for my $c (@$base) {
        my $bucket = $self->_candle_bucket($tf, $c);
        next unless defined $bucket;

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
        }
        else {
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

# Construye todos los TFs derivados a partir de 1m.
sub build_timeframes {
    my ($self) = @_;
    $self->build_tf_candles($_) for qw(5m 15m 1h 2h 4h D W);
    return;
}

# ============================================================
#  Control de timeframe activo
# ============================================================

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

# ============================================================
#  Acceso a velas
# ============================================================

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

sub get_timestamp {
    my ($self, $index) = @_;
    my $c = $self->get_candle($index);
    return defined $c ? $c->{time} : undef;
}

# ============================================================
#  Anchors de eje de tiempo (para etiquetas en el grafico)
# ============================================================

sub compute_time_anchors {
    my ($self) = @_;
    my $arr  = $self->_active_array;
    my $tf   = $self->{timeframe};
    my @anchors;
    my $prev_key = '';
    my $prev_day = '';

    for my $i (0 .. $#$arr) {
        my $ts = $arr->[$i]{time};
        my ($key, $h, $is_new_day);

        if ($tf eq 'D' || $tf eq 'W') {
            # Para D y W cada vela ya es su propio bucket
            $key        = $ts;
            $h          = 0;
            $is_new_day = 1;
        }
        else {
            my ($Y, $Mo, $D, $hh, $mi) = $ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/;
            next unless defined $mi;
            $h = $hh + 0;
            my $day       = "$Y-$Mo-$D";
            my $total_min = $hh * 60 + $mi;
            my $slot      = int($total_min / ($ANCHOR_SLOT{$tf} // 60));
            $key        = "$day:$slot";
            $is_new_day = ($day ne $prev_day && $prev_day ne '') ? 1 : 0;
            $prev_day   = $day;
        }

        if ($key ne $prev_key) {
            push @anchors, {
                index      => $i,
                time       => $ts,
                hour       => $h,
                is_new_day => $is_new_day,
            };
            $prev_key = $key;
        }
    }
    return \@anchors;
}

1;
