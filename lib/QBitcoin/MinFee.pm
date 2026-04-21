package QBitcoin::MinFee;
use warnings;
use strict;

use Exporter qw(import);
our @EXPORT_OK = qw(min_fee MIN_FEE);

use constant {
    FEE_LINEAR_SIZE => 32768,   # 32K
    MIN_FEE_REDUCE  => 0.9,     # Reduce min_fee by 10% for the next block if the size is reduced
    TINY_BLOCK_SIZE => 256,     # Block less than this size is considered as tiny: reset min_fee
    POWER2_RADIX    => 10000,   # Radix in @POWER2 array for store as integers
    SIZE_FRACTION   => 64,      # Size fraction for @POWER2 array (bytes)
    MIN_FEE         => 10,      # 10 satoshi/kb -- less fee allowed, but only MAX_EMPTY_TX_IN_BLOCK per block
    MAX_MIN_FEE     => 1000000, # 0.01 qbtc/kb  -- it's not maximum allowed fee, it's only maximum for min_fee
};

# 2 ** (i/256)
# perl -e 'for (0..511) { printf "%.0f,", 2**($_/256)*10000; print "\n" unless ($_+1)%16 }'
my @POWER2 = (
    10000,10027,10054,10082,10109,10136,10164,10191,10219,10247,10274,10302,10330,10358,10386,10415,
    10443,10471,10499,10528,10556,10585,10614,10643,10671,10700,10729,10758,10788,10817,10846,10876,
    10905,10935,10964,10994,11024,11054,11084,11114,11144,11174,11204,11235,11265,11296,11326,11357,
    11388,11419,11450,11481,11512,11543,11574,11606,11637,11669,11700,11732,11764,11796,11828,11860,
    11892,11924,11957,11989,12022,12054,12087,12120,12152,12185,12218,12252,12285,12318,12352,12385,
    12419,12452,12486,12520,12554,12588,12622,12656,12691,12725,12759,12794,12829,12863,12898,12933,
    12968,13004,13039,13074,13110,13145,13181,13217,13252,13288,13324,13360,13397,13433,13469,13506,
    13543,13579,13616,13653,13690,13727,13764,13802,13839,13877,13914,13952,13990,14028,14066,14104,
    14142,14180,14219,14257,14296,14335,14374,14413,14452,14491,14530,14570,14609,14649,14689,14728,
    14768,14808,14848,14889,14929,14970,15010,15051,15092,15133,15174,15215,15256,15297,15339,15380,
    15422,15464,15506,15548,15590,15632,15675,15717,15760,15803,15845,15888,15931,15975,16018,16061,
    16105,16149,16192,16236,16280,16324,16369,16413,16458,16502,16547,16592,16637,16682,16727,16772,
    16818,16864,16909,16955,17001,17047,17093,17140,17186,17233,17280,17326,17373,17420,17468,17515,
    17563,17610,17658,17706,17754,17802,17850,17899,17947,17996,18045,18093,18143,18192,18241,18290,
    18340,18390,18440,18490,18540,18590,18640,18691,18742,18792,18843,18895,18946,18997,19049,19100,
    19152,19204,19256,19308,19361,19413,19466,19519,19571,19625,19678,19731,19785,19838,19892,19946,
    20000,20054,20109,20163,20218,20273,20328,20383,20438,20493,20549,20605,20660,20717,20773,20829,
    20885,20942,20999,21056,21113,21170,21228,21285,21343,21401,21459,21517,21575,21634,21692,21751,
    21810,21869,21929,21988,22048,22107,22167,22227,22288,22348,22409,22470,22530,22592,22653,22714,
    22776,22838,22899,22962,23024,23086,23149,23212,23274,23338,23401,23464,23528,23592,23656,23720,
    23784,23849,23913,23978,24043,24108,24174,24239,24305,24371,24437,24503,24570,24636,24703,24770,
    24837,24904,24972,25040,25108,25176,25244,25312,25381,25450,25519,25588,25657,25727,25797,25867,
    25937,26007,26078,26148,26219,26290,26362,26433,26505,26577,26649,26721,26793,26866,26939,27012,
    27085,27159,27232,27306,27380,27454,27529,27603,27678,27753,27828,27904,27980,28055,28132,28208,
    28284,28361,28438,28515,28592,28670,28748,28825,28904,28982,29061,29139,29218,29298,29377,29457,
    29537,29617,29697,29777,29858,29939,30020,30102,30183,30265,30347,30429,30512,30595,30678,30761,
    30844,30928,31012,31096,31180,31265,31349,31434,31520,31605,31691,31777,31863,31949,32036,32123,
    32210,32297,32385,32473,32561,32649,32737,32826,32915,33004,33094,33184,33274,33364,33454,33545,
    33636,33727,33818,33910,34002,34094,34187,34279,34372,34466,34559,34653,34747,34841,34935,35030,
    35125,35220,35316,35412,35508,35604,35700,35797,35894,35992,36089,36187,36285,36383,36482,36581,
    36680,36780,36879,36979,37080,37180,37281,37382,37483,37585,37687,37789,37892,37994,38097,38201,
    38304,38408,38512,38617,38721,38826,38931,39037,39143,39249,39355,39462,39569,39676,39784,39892,
);

@POWER2 == int((FEE_LINEAR_SIZE + SIZE_FRACTION - 1) / SIZE_FRACTION)
    or die "POWER2 array size is not correct: " . scalar(@POWER2) . " != " . int((FEE_LINEAR_SIZE + SIZE_FRACTION - 1) / SIZE_FRACTION);

sub min_fee {
    my ($prev_block, $size) = @_;
    # Allow any fee for tiny blocks, and tiny block resets min_fee
    # This is to avoid the situation where big coinbase transaction(s) increase block size and set min_fee too high
    # Also allow transactions with fee less than MIN_FEE to be included in the tiny blocks in addition to zero-fee transactions
    return 0 if $size < TINY_BLOCK_SIZE;
    return MIN_FEE if !$prev_block;
    my $min_fee = $prev_block->min_fee;
    $min_fee = MIN_FEE if $min_fee < MIN_FEE;
    my $prev_size = $prev_block->size;
    if ($prev_size >= $size) {
        if ($prev_size > FEE_LINEAR_SIZE) {
            if ($size >= FEE_LINEAR_SIZE) {
                $min_fee = int($min_fee * $size * MIN_FEE_REDUCE / $prev_size);
                return $min_fee < MIN_FEE ? MIN_FEE : $min_fee;
            }
            $min_fee = int($min_fee * FEE_LINEAR_SIZE / $prev_size);
            return MIN_FEE if $min_fee <= MIN_FEE;
            $prev_size = FEE_LINEAR_SIZE;
        }
        $min_fee = int($min_fee * POWER2_RADIX * MIN_FEE_REDUCE / $POWER2[int(($prev_size - $size) / SIZE_FRACTION)]);
        return $min_fee < MIN_FEE ? MIN_FEE : $min_fee;
    }
    # Increase min_fee twice for each 16KB increase in block size until size reaches 32K
    # Then increase min_fee proportionally for increase in size
    # Avoid floating point arithmetic (exponent and logarithms) for deterministic results (depending on system and perl version)
    if ($prev_size < FEE_LINEAR_SIZE) {
        # Exponential part
        if ($size <= FEE_LINEAR_SIZE) {
            $min_fee *= $POWER2[int(($size - $prev_size) / SIZE_FRACTION)];
            $min_fee = int($min_fee / POWER2_RADIX);
            return $min_fee > MAX_MIN_FEE ? MAX_MIN_FEE : $min_fee;
        }
        my $size_increase = FEE_LINEAR_SIZE - $prev_size;
        $min_fee *= $POWER2[int($size_increase / SIZE_FRACTION)];
        $min_fee = int($min_fee / POWER2_RADIX);
        $prev_size = FEE_LINEAR_SIZE;
    }
    $min_fee = int($min_fee * $size / $prev_size);
    return $min_fee > MAX_MIN_FEE ? MAX_MIN_FEE : $min_fee;
}

1;
