#!/bin/zsh
# Find Mono — macOS Finder Quick Action that finds mono audio hidden in stereo files
# and can turn those files into real mono files.
#
# - Analyzes every selected file:
#     100% Mono    both channels carry the same signal (bit for bit, or apart from
#                  an inaudible dither noise): converted to mono
#     99.9% Mono   the difference between the channels is at least 40 dB below
#                  the signal: converted if its box is ticked
#     Fake Mono    a mono signal panned to one side, or with one channel in
#                  inverted polarity: converted if its box is ticked
#     Left / Right channel only, Real stereo, Mono...
# - Works on files and on folders: a folder is searched with all its subfolders,
#   and only its WAV, AIFF, CAF and FLAC files are analyzed (every other file is
#   ignored, and so are hidden files and the "Mono" folders made by Duplicate).
# - Several files (or a folder) selected: only the files with something to do are
#   listed (with the number of stereo and mono files found).
# - Overwrite the originals, or duplicate them into a "Mono" subfolder.
# - Nothing is recomputed: the mono file keeps one channel exactly as it was (bit
#   for bit), and every converted file is checked against the original first.
# - Lossless formats only: WAV, AIFF/AIF/AIFC, CAF (uncompressed PCM) and FLAC.
#   Other files are skipped.
# - WAV / AIFF / CAF: every chunk is kept byte for byte (Apple Loops metadata,
#   markers, ID3 tags...), except the ones that describe the channels. Finder tags
#   and Spotlight comments are kept too. Bit depth and sample rate never change.
# - FLAC: re-encoded to mono FLAC with ffmpeg, keeping tags and cover art.
#
# Requires ffmpeg. Runs with /bin/zsh.

copydir="Mono"                 # subfolder used by "Duplicate"
# Channels that differ by no more than this many steps of the file's resolution
# (dither noise) still count as fake stereo.
dither_steps=8

export LC_NUMERIC=C

FFMPEG=""
for p in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
  [[ -x $p ]] && { FFMPEG=$p; break; }
done
FFPROBE=${FFMPEG%/*}/ffprobe

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/findmono.XXXXXX") || exit 1
trap 'rm -rf "$tmpdir"' EXIT
pl="$tmpdir/afmeta.pl"

# --- File structure helper -------------------------------------------------------
#   scan FILE...                 one line per file: "pcm ENC BITS ENDIAN OFFSET LENGTH
#                                CHANNELS RATE", "flac BITS RATE", "lossy",
#                                "compressed", "unreadable" or "none"
#   extract FILE OFFSET LENGTH   writes the audio bytes to stdout
#   splice FILE OFFSET LENGTH RAW  overwrites the audio bytes with RAW (same size)
#   flacinfo FILE                prints "BITS RATE"
#   mono SRC DST [CH]            writes DST: SRC with only channel CH (0 = left,
#                                1 = right), every other chunk kept byte for byte
cat > "$pl" <<'PERL'
use strict; use warnings;
my $mode = shift @ARGV // '';

if ($mode eq 'scan') {
    for my $path (@ARGV) { print scan_one($path), "\n" }
    exit 0;
}
if ($mode eq 'extract') {
    my ($path, $off, $len) = @ARGV;
    open(my $in, '<:raw', $path) or exit 1;
    binmode STDOUT;
    seek($in, $off, 0) or exit 1;
    my $buf;
    while ($len > 0) {
        my $n = read($in, $buf, $len < 1048576 ? $len : 1048576) or last;
        print STDOUT $buf or exit 1;
        $len -= $n;
    }
    exit($len == 0 ? 0 : 1);
}
if ($mode eq 'splice') {
    my ($path, $off, $len, $raw) = @ARGV;
    (-s $raw || 0) == $len or exit 3;
    open(my $out, '+<:raw', $path) or exit 1;
    open(my $in,  '<:raw',  $raw)  or exit 1;
    seek($out, $off, 0) or exit 1;
    my $buf;
    while (read($in, $buf, 1048576)) { print {$out} $buf or exit 1 }
    close($out) or exit 1;
    exit 0;
}
if ($mode eq 'mono') {   # mono SRC DST [CH]: DST = SRC with only channel CH (0 = left)
    my ($src, $dst, $keep) = @ARGV;
    my $r = eval { mono_file($src, $dst, $keep // 0); 1 };
    unless ($r) { unlink $dst; print STDERR $@; exit 1 }
    exit 0;
}
if ($mode eq 'flacinfo') {
    my @r = eval { open(my $fh, '<:raw', $ARGV[0]) or die "open\n"; flac($fh) };
    print @r ? "$r[1] $r[2]\n" : "?\n";
    exit 0;
}
exit 1;

sub scan_one {
    my ($path) = @_;
    return 'none' unless -f $path;
    return 'lossy' unless $path =~ /\.(wav|aiff?|aifc|caf|flac)\z/i;
    my $is_flac = lc($1) eq 'flac';
    my @r = eval {
        open(my $fh, '<:raw', $path) or die "open\n";
        return flac($fh) if $is_flac;
        my $size = -s $fh;
        read($fh, my $hdr, 12) == 12 or die "short\n";
        my $id = substr($hdr, 0, 4);
        return $id eq 'FORM' ? aiff($fh, $size, substr($hdr, 8, 4))
             : ($id eq 'RIFF' || $id eq 'RF64' || $id eq 'BW64') ? wav($fh, $size, substr($hdr, 8, 4))
             : $id eq 'caff' ? caf($fh, $size)
             : die "container\n";
    };
    return join(' ', @r) if @r;
    return $@ =~ /^codec/ ? 'compressed' : 'unreadable';
}

sub clamp_len {   # bytes actually present, rounded down to whole frames
    my ($size, $off, $len, $frame) = @_;
    $len = $size - $off if $off + $len > $size;
    die "frame\n" if $frame <= 0 || $len < 0;
    return $len - ($len % $frame);
}
sub rate_ok { my $r = sprintf('%.0f', $_[0] || 0); $r >= 1000 && $r <= 1536000 ? $r : 44100 }

sub aiff {
    my ($fh, $size, $form) = @_;
    $form eq 'AIFF' || $form eq 'AIFC' or die "form\n";
    my ($ch, $frames, $bits, $rate, $comp, $soff, $slen);
    my $pos = 12;
    while ($pos + 8 <= $size) {
        seek($fh, $pos, 0); read($fh, my $h, 8) == 8 or last;
        my ($cid, $clen) = unpack('a4 N', $h);
        if ($cid eq 'COMM') {
            read($fh, my $c, $clen < 64 ? $clen : 64);
            length($c) >= 18 or die "comm\n";
            ($ch, $frames, $bits) = unpack('n N n', $c);
            my ($e, $hi, $lo) = unpack('n N N', substr($c, 8, 10));
            $rate = ($hi * 4294967296 + $lo) * 2 ** (($e & 0x7FFF) - 16383 - 63);
            $comp = ($form eq 'AIFC' && length($c) >= 22) ? substr($c, 18, 4) : 'NONE';
        } elsif ($cid eq 'SSND') {
            read($fh, my $s, 8) == 8 or die "ssnd\n";
            my ($o) = unpack('N', $s);
            ($soff, $slen) = ($pos + 16 + $o, $clen - 8 - $o);
        }
        $pos += 8 + $clen + ($clen & 1);
    }
    defined $ch && defined $soff && $ch > 0 or die "chunks\n";
    my %c = (NONE => ['signed-integer', 'B'], twos => ['signed-integer', 'B'],
             sowt => ['signed-integer', 'L'], in24 => ['signed-integer', 'B', 24],
             in32 => ['signed-integer', 'B', 32], '23ni' => ['signed-integer', 'L', 24],
             fl32 => ['floating-point', 'B', 32], FL32 => ['floating-point', 'B', 32],
             fl64 => ['floating-point', 'B', 64], FL64 => ['floating-point', 'B', 64]);
    my $e = $c{$comp} or die "codec $comp\n";
    my $bytes = int((($e->[2] // $bits) + 7) / 8);
    my $len = $frames * $ch * $bytes;
    $len = $slen if $slen < $len;
    return ('pcm', $e->[0], 8 * $bytes, $e->[1], $soff,
            clamp_len($size, $soff, $len, $ch * $bytes), $ch, rate_ok($rate));
}

sub wav {
    my ($fh, $size, $wave) = @_;
    $wave eq 'WAVE' or die "wave\n";
    my ($fmt, $doff, $dlen, $ds64);
    my $pos = 12;
    while ($pos + 8 <= $size) {
        seek($fh, $pos, 0); read($fh, my $h, 8) == 8 or last;
        my ($cid, $clen) = unpack('a4 V', $h);
        if ($cid eq 'ds64') {
            read($fh, my $d, 16) == 16 or die "ds64\n";
            my (undef, undef, $lo, $hi) = unpack('V4', $d);
            $ds64 = $hi * 4294967296 + $lo;
        } elsif ($cid eq 'fmt ') {
            read($fh, $fmt, $clen < 40 ? $clen : 40);
        } elsif ($cid eq 'data' && !defined $doff) {
            $clen = $ds64 if $clen == 0xFFFFFFFF && defined $ds64;
            ($doff, $dlen) = ($pos + 8, $clen);
        }
        $pos += 8 + $clen + ($clen & 1);
    }
    defined $fmt && defined $doff && length($fmt) >= 16 or die "chunks\n";
    my ($tag, $ch, $rate, undef, $align, $bits) = unpack('v v V V v v', $fmt);
    $tag = unpack('v', substr($fmt, 24, 2)) if $tag == 0xFFFE && length($fmt) >= 26;
    $ch > 0 && $align > 0 && $align % $ch == 0 or die "fmt\n";
    my $bytes = $align / $ch;
    my $enc = $tag == 3 ? 'floating-point'
            : $tag == 1 ? ($bytes == 1 ? 'unsigned-integer' : 'signed-integer')
            : die "codec $tag\n";
    return ('pcm', $enc, 8 * $bytes, 'L', $doff,
            clamp_len($size, $doff, $dlen, $align), $ch, rate_ok($rate));
}

sub caf {
    my ($fh, $size) = @_;
    my ($desc, $doff, $dlen);
    my $pos = 8;
    while ($pos + 12 <= $size) {
        seek($fh, $pos, 0); read($fh, my $h, 12) == 12 or last;
        my ($cid, $hi, $lo) = unpack('a4 N N', $h);
        my $clen = ($hi == 0xFFFFFFFF && $lo == 0xFFFFFFFF) ? $size - $pos - 12
                 : $hi * 4294967296 + $lo;
        if ($cid eq 'desc') { read($fh, $desc, 32) == 32 or die "desc\n" }
        elsif ($cid eq 'data') { ($doff, $dlen) = ($pos + 16, $clen - 4) }
        $pos += 12 + $clen;
    }
    defined $desc && defined $doff or die "chunks\n";
    my ($rate, $fid, $flags, $bpp, undef, $ch) = unpack('d> a4 N N N N', $desc);
    $fid eq 'lpcm' or die "codec $fid\n";
    $ch > 0 && $bpp > 0 && $bpp % $ch == 0 or die "desc\n";
    my $enc = ($flags & 1) ? 'floating-point' : 'signed-integer';
    my $end = ($flags & 2) ? 'L' : 'B';
    return ('pcm', $enc, 8 * $bpp / $ch, $end, $doff,
            clamp_len($size, $doff, $dlen, $bpp), $ch, rate_ok($rate));
}

sub flac {   # STREAMINFO, after an optional ID3v2 tag
    my ($fh) = @_;
    read($fh, my $h, 10) == 10 or die "short\n";
    my $pos = 0;
    if (substr($h, 0, 3) eq 'ID3') {
        my @s = unpack('C4', substr($h, 6, 4));
        $pos = 10 + (($s[0] << 21) | ($s[1] << 14) | ($s[2] << 7) | $s[3]);
        $pos += 10 if ord(substr($h, 5, 1)) & 0x10;
    }
    seek($fh, $pos, 0); read($fh, my $b, 42) == 42 or die "short\n";
    substr($b, 0, 4) eq 'fLaC' && (ord(substr($b, 4, 1)) & 0x7F) == 0 or die "flac\n";
    my @s = unpack('C*', substr($b, 8, 34));
    my $rate = ($s[10] << 12) | ($s[11] << 4) | ($s[12] >> 4);
    my $bits = ((($s[12] & 1) << 4) | ($s[13] >> 4)) + 1;
    return ('flac', $bits, $rate);
}

# --- Mono conversion -------------------------------------------------------------
# Every chunk is copied byte for byte, except the ones that describe the channels:
# WAV fmt / ds64 / PEAK, AIFF COMM / SSND / CHAN / PEAK, CAF desc / data / chan /
# peak. The audio data keeps one channel of each frame, bit for bit (nothing is
# recomputed).
my ($IN, $OUT);
sub rd { my ($pos, $len) = @_; seek($IN, $pos, 0) or die "seek\n"; my $b = '';
         $len > 0 && (read($IN, $b, $len) // die "read\n"); return $b }
sub wr { print {$OUT} @_ or die "write\n" }
sub copy_range { my ($pos, $len) = @_; seek($IN, $pos, 0) or die "seek\n";
    while ($len > 0) { my $n = read($IN, my $b, $len < 1048576 ? $len : 1048576);
                       die "read\n" unless $n; wr($b); $len -= $n } }
my $KEEP = 0;      # channel kept: 0 = left, 1 = right
sub mono_data {   # copies channel $KEEP of each frame; returns the bytes written
    my ($pos, $len, $frame, $bytes) = @_;
    my $per = $frame * 16384;
    my $before = $KEEP * $bytes;
    my $tpl = '(' . ($before ? "x$before " : '') . "a$bytes x" . ($frame - $bytes - $before) . ')*';
    my $done = 0;
    seek($IN, $pos, 0) or die "seek\n";
    while ($len > 0) {
        my $want = $len < $per ? $len : $per;
        my $n = read($IN, my $b, $want);
        die "read\n" unless $n && $n == $want;
        my $m = join('', unpack($tpl, $b));
        wr($m); $done += length($m); $len -= $want;
    }
    return $done;
}
sub mono_layout { pack("N N N", (100 << 16) | 1, 0, 0) }   # kAudioChannelLayoutTag_Mono

sub mono_file {
    my ($src, $dst, $keep) = @_;
    $KEEP = $keep ? 1 : 0;
    my @s = split ' ', scan_one($src);
    $s[0] eq 'pcm' or die "not pcm\n";
    my (undef, undef, $bits, undef, $doff, $dlen, $ch) = @s;
    $ch == 2 or die "not stereo\n";
    my $bytes = $bits / 8;
    my $frame = $ch * $bytes;
    open($IN, '<:raw', $src) or die "open\n";
    open($OUT, '>:raw', $dst) or die "create\n";
    my $size = -s $IN;
    my $id = rd(0, 4);
    if ($id eq 'FORM') { aiff_mono($size, $doff, $dlen, $frame, $bytes) }
    elsif ($id eq 'caff') { caf_mono($size, $doff, $dlen, $frame, $bytes) }
    else { wav_mono($size, $doff, $dlen, $frame, $bytes) }
    close($OUT) or die "write\n";
    close($IN);
}

sub wav_mono {
    my ($size, $doff, $dlen, $frame, $bytes) = @_;
    my $rf64 = rd(0, 4) ne 'RIFF';
    wr(rd(0, 12));
    my ($ds64_at, $newlen);
    my $pos = 12;
    while ($pos + 8 <= $size) {
        my ($cid, $clen) = unpack('a4 V', rd($pos, 8));
        my $body = $pos + 8;
        if ($cid eq 'data' && $body == $doff) {
            $newlen = $dlen / $frame * $bytes;
            wr(pack('a4 V', 'data', $rf64 && $clen == 0xFFFFFFFF ? 0xFFFFFFFF : $newlen));
            mono_data($doff, $dlen, $frame, $bytes);
            wr("\0") if $newlen & 1;
            $clen = $dlen if $clen == 0xFFFFFFFF;
        } elsif ($cid eq 'fmt ') {
            my $f = rd($body, $clen);
            my $rate = unpack('V', substr($f, 4, 4));
            substr($f, 2, 2) = pack('v', 1);
            substr($f, 8, 4) = pack('V', $rate * $bytes);
            substr($f, 12, 2) = pack('v', $bytes);
            substr($f, 20, 4) = pack('V', 4)   # channel mask: front center
                if $clen >= 24 && unpack('v', $f) == 0xFFFE;
            wr(pack('a4 V', $cid, $clen), $f, $clen & 1 ? "\0" : '');
        } elsif ($cid eq 'ds64') {
            $ds64_at = tell($OUT) + 8;
            wr(pack('a4 V', $cid, $clen), rd($body, $clen + ($clen & 1)));
        } elsif ($cid eq 'PEAK' && $clen == 8 + 8 * 2) {
            wr(pack('a4 V', $cid, 16), rd($body, 16));
        } else {
            my $n = $clen + ($clen & 1);
            $n = $size - $pos - 8 if $pos + 8 + $n > $size;
            wr(pack('a4 V', $cid, $clen)); copy_range($body, $n);
        }
        $pos = $body + $clen + ($clen & 1);
    }
    copy_range($pos, $size - $pos) if $pos < $size;   # trailing bytes, if any
    defined $newlen or die "data\n";
    my $total = tell($OUT);
    if ($rf64) {
        defined $ds64_at or die "ds64\n";
        seek($OUT, $ds64_at, 0);
        wr(pack('V V V V', ($total - 8) % 4294967296, int(($total - 8) / 4294967296),
                           $newlen % 4294967296, int($newlen / 4294967296)));
    } else {
        seek($OUT, 4, 0); wr(pack('V', $total - 8));
    }
}

sub aiff_mono {
    my ($size, $doff, $dlen, $frame, $bytes) = @_;
    wr(rd(0, 12));
    my ($pos, $done) = (12, 0);
    while ($pos + 8 <= $size) {
        my ($cid, $clen) = unpack('a4 N', rd($pos, 8));
        my $body = $pos + 8;
        if ($cid eq 'SSND') {
            my $pre = $doff - $body;            # offset + blockSize fields + offset bytes
            my $newlen = $dlen / $frame * $bytes;
            wr(pack('a4 N', $cid, $pre + $newlen), rd($body, $pre));
            mono_data($doff, $dlen, $frame, $bytes);
            wr("\0") if ($pre + $newlen) & 1;
            $done = 1;
        } elsif ($cid eq 'COMM') {
            my $c = rd($body, $clen);
            substr($c, 0, 2) = pack('n', 1);
            wr(pack('a4 N', $cid, $clen), $c, $clen & 1 ? "\0" : '');
        } elsif ($cid eq 'CHAN') {
            wr(pack('a4 N', $cid, length mono_layout()), mono_layout());
        } elsif ($cid eq 'PEAK' && $clen == 8 + 8 * 2) {
            wr(pack('a4 N', $cid, 16), rd($body, 16));
        } else {
            my $n = $clen + ($clen & 1);
            $n = $size - $pos - 8 if $pos + 8 + $n > $size;
            wr(pack('a4 N', $cid, $clen)); copy_range($body, $n);
        }
        $pos = $body + $clen + ($clen & 1);
    }
    copy_range($pos, $size - $pos) if $pos < $size;
    $done or die "ssnd\n";
    my $total = tell($OUT);
    seek($OUT, 4, 0); wr(pack('N', $total - 8));
}

sub caf_mono {
    my ($size, $doff, $dlen, $frame, $bytes) = @_;
    wr(rd(0, 8));
    my ($pos, $done) = (8, 0);
    while ($pos + 12 <= $size) {
        my ($cid, $hi, $lo) = unpack('a4 N N', rd($pos, 12));
        my $clen = ($hi == 0xFFFFFFFF && $lo == 0xFFFFFFFF) ? $size - $pos - 12
                 : $hi * 4294967296 + $lo;
        my $body = $pos + 12;
        my $hdr = sub { my $n = shift; pack('a4 N N', $cid, int($n / 4294967296), $n % 4294967296) };
        if ($cid eq 'data') {
            my $newlen = $dlen / $frame * $bytes;
            wr($hdr->(4 + $newlen), rd($body, 4));
            mono_data($doff, $dlen, $frame, $bytes);
            $done = 1;
        } elsif ($cid eq 'desc') {
            my $d = rd($body, $clen);
            substr($d, 16, 4) = pack('N', $bytes);   # bytes per packet
            substr($d, 24, 4) = pack('N', 1);        # channels per frame
            wr($hdr->($clen), $d);
        } elsif ($cid eq 'chan') {
            wr($hdr->(length mono_layout()), mono_layout());
        } elsif ($cid eq 'peak' && $clen == 4 + 12 * 2) {
            wr($hdr->(16), rd($body, 16));
        } else {
            my $n = $clen;
            $n = $size - $body if $body + $n > $size;
            wr($hdr->($clen)); copy_range($body, $n);
        }
        $pos = $body + $clen;
    }
    copy_range($pos, $size - $pos) if $pos < $size;
    $done or die "data\n";
}
PERL

notify() {
  /usr/bin/osascript -e 'on run argv' \
    -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
    -e 'end run' "$1" "$2" >/dev/null 2>&1
}
alert() {
  /usr/bin/osascript -e 'on run argv' \
    -e 'display alert (item 1 of argv) message (item 2 of argv) as warning' \
    -e 'end run' "$1" "$2" >/dev/null 2>&1
}
plural() {   # plural 3 file -> "3 files"
  if (( $1 == 1 )); then print -r -- "$1 $2"; else print -r -- "$1 $2s"; fi
}

if [[ -z $FFMPEG || ! -x $FFPROBE ]]; then
  alert "ffmpeg not found" "Find Mono needs ffmpeg. Install it with Homebrew: brew install ffmpeg"
  exit 0
fi

# --- Jobs ------------------------------------------------------------------------
# Analysis, in double precision: writes "ch <channels>" (not stereo),
# "st <peak L> <R> <L-R> <L+R> <RMS L> <R> <L-R> <L+R>" (dBFS, -inf for digital
# silence) or "err" to $tmpdir/a<n>.res
analyze() {   # n file
  local ch
  ch=$("$FFPROBE" -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$2" 2>/dev/null)
  ch=${ch%%[^0-9]*}
  if [[ -z $ch ]]; then print err > "$tmpdir/a$1.res"; return; fi
  if (( ch != 2 )); then print "ch $ch" > "$tmpdir/a$1.res"; return; fi
  "$FFMPEG" -nostdin -hide_banner -nostats -i "$2" -map 0:a:0 \
      -af "aformat=sample_fmts=dbl,pan=4c|c0=c0|c1=c1|c2=c0-c1|c3=c0+c1,astats=measure_perchannel=Peak_level+RMS_level:measure_overall=none" \
      -f null - 2>&1 \
    | awk '/Peak level dB/ { p[++k] = $NF }
           /RMS level dB/  { r[++j] = $NF }
           END { if (k < 4 || j < 4) print "err"
                 else print "st", p[1], p[2], p[3], p[4], r[1], r[2], r[3], r[4] }' > "$tmpdir/a$1.res"
}

# Audio of one channel of SRC compared with the audio of OUT, sample by sample
same_audio() {   # src out channel(0 = left, 1 = right)
  local a b
  a=$("$FFMPEG" -nostdin -v error -i "$1" -map 0:a:0 -af "pan=mono|c0=c$3" -c:a pcm_f64le -f md5 - 2>/dev/null)
  b=$("$FFMPEG" -nostdin -v error -i "$2" -map 0:a:0 -c:a pcm_f64le -f md5 - 2>/dev/null)
  [[ -n $a && $a == $b ]]
}

# The converted file replaces the destination only once it is complete and
# checked. cp -p then overwriting the content keeps Finder tags and comments.
install_result() {   # src out partial converted res
  if cp -p "$1" "$3" && cat "$4" > "$3" && touch "$3" && mv -f "$3" "$2"; then
    print ok > "$5"
  else
    rm -f "$3"; print -r -- "err could not write the file" > "$5"
  fi
  rm -f "$4"
}

# WAV / AIFF / CAF: rewritten with only one channel, every other chunk kept
mono_pcm_job() {   # n src out partial channel
  local conv="$tmpdir/$1.conv" res="$tmpdir/$1.res"
  if ! /usr/bin/perl "$pl" mono "$2" "$conv" "$5" 2>/dev/null; then
    rm -f "$conv"; print -r -- "err unexpected file structure" > "$res"; return
  fi
  if ! same_audio "$2" "$conv" "$5"; then
    rm -f "$conv"; print -r -- "err check failed, file not written" > "$res"; return
  fi
  install_result "$2" "$3" "$4" "$conv" "$res"
}

# FLAC: re-encoded to mono FLAC (one channel), same bit depth and sample rate
mono_flac_job() {   # n src out partial bits rate channel
  local conv="$tmpdir/$1.flac" res="$tmpdir/$1.res"
  local -a fmt
  case $5 in
    16) fmt=(-sample_fmt s16) ;;
    24) fmt=(-sample_fmt s32 -bits_per_raw_sample 24) ;;
    32) fmt=(-sample_fmt s32 -bits_per_raw_sample 32 -strict experimental) ;;
    *)  print -r -- "err unsupported FLAC bit depth (${5}-bit)" > "$res"; return ;;
  esac
  if ! "$FFMPEG" -nostdin -v error -y -i "$2" -map 0:a:0 -map '0:v?' -map_metadata 0 \
       -c copy -c:a flac "${fmt[@]}" -ar "$6" -af "pan=mono|c0=c$7" "$conv"; then
    rm -f "$conv"; print -r -- "err ffmpeg failed" > "$res"; return
  fi
  if [[ $(/usr/bin/perl "$pl" flacinfo "$conv") != "$5 $6" ]] || ! same_audio "$2" "$conv" "$7"; then
    rm -f "$conv"; print -r -- "err check failed, file not written" > "$res"; return
  fi
  install_result "$2" "$3" "$4" "$conv" "$res"
}

maxjobs=$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null)
[[ $maxjobs == <-> ]] || maxjobs=4
(( maxjobs > 6 )) && maxjobs=6
(( maxjobs < 1 )) && maxjobs=1

# --- 1. Scan (headers only) and analyze every file -----------------------------------
# Selected folders are searched with all their subfolders, for WAV, AIFF, CAF and
# FLAC files only; every other file is ignored, and so are hidden files (such as
# the "._" files macOS writes on external drives) and the "Mono" folders made by
# Duplicate. Files found in a folder are shown with their path inside it.
files=() labels=() infos=() folders=0
add_folder() {   # folder
  setopt localoptions extendedglob
  local d=${1%/} g
  for g in $d/**/*.(#i)(wav|aif|aiff|aifc|caf|flac)(N.n); do
    [[ ${g#$d/} == (*/|)${copydir}/* ]] && continue
    files+=("$g"); labels+=("${g#$d/}")
  done
}
for f in "$@"; do
  if [[ -d $f ]]; then
    (( folders++ )); add_folder "$f"
  elif [[ -f $f ]]; then
    files+=("$f"); labels+=("${f##*/}")
  fi
done
if (( ${#files} == 0 )); then
  if (( folders == 1 )); then
    alert "No lossless audio file found" "There is no WAV, AIFF, CAF or FLAC file in the selected folder."
  elif (( folders > 1 )); then
    alert "No lossless audio file found" "There is no WAV, AIFF, CAF or FLAC file in the selected folders."
  fi
  exit 0
fi
# headers are read 200 files at a time (long argument lists)
for (( i = 1; i <= ${#files}; i += 200 )); do
  infos+=("${(@f)$(/usr/bin/perl "$pl" scan "${(@)files[i,i+199]}")}")
done

if [[ ${(M)infos:#(pcm|flac) *} == "" ]]; then
  alert "No lossless audio file selected" "Find Mono works on WAV, AIFF, CAF and FLAC files."
  exit 0
fi

pids=()
for (( n = 1; n <= ${#files}; n++ )); do
  [[ ${infos[n]} == (pcm|flac)\ * ]] || continue
  analyze $n "${files[n]}" &
  pids+=($!)
  if (( ${#pids} >= maxjobs )); then wait ${pids[1]}; shift pids; fi
done
wait

# --- 2. Results --------------------------------------------------------------------
# kind: "fake" (converted), "opt" (converted if its box is ticked), "info" (shown
# only) or "err"
specs=()          # one entry per file shown
spec_file=()      # file number of each entry (0: skipped / unreadable)
todo=()           # fake stereo files: always converted
keep=()           # channel kept for each file: 0 = left, 1 = right
nopt=0         # files with a "Convert to mono" box
# Several files selected: only the files with something to do are listed
batch=$(( ${#files} > 1 || folders > 0 ))
n_mono=0 n_stereo=0 n_other=0 n_lossy=0   # files left out of the list
for (( n = 1; n <= ${#files}; n++ )); do
  name=${labels[n]}
  r=""
  [[ -f $tmpdir/a$n.res ]] && r=$(<"$tmpdir/a$n.res")
  info=(${=infos[n]})
  case ${info[1]} in
    pcm)  bits=${info[3]}; [[ ${info[2]} == floating-point ]] && bits=24 ;;
    flac) bits=${info[2]} ;;
    compressed) (( batch )) && { (( n_lossy++ )); continue }
                specs+=("${name}"$'\n'"!Skipped (compressed audio)"); spec_file+=(0); continue ;;
    *)    (( batch )) && { (( n_lossy++ )); continue }
          specs+=("${name}"$'\n'"!Skipped (not a WAV, AIFF, CAF or FLAC file)"); spec_file+=(0); continue ;;
  esac
  # Fake stereo: both channels identical, or differing only by dither noise (a few
  # steps of the file's resolution). Panned or inverted mono is reported, not
  # converted. The correlation of the channels comes from the RMS levels:
  # sum(L.R) = (rms(L+R)^2 - rms(L-R)^2) / 4.
  out=$(print -r -- "$r" | awk -v bits="$bits" -v steps="$dither_steps" '
    function db(x) { return x == "-inf" ? -1000 : x + 0 }
    function lin(x) { return x <= -1000 ? 0 : 10 ^ (x / 20) }
    function abs(x) { return x < 0 ? -x : x }
    $1 == "ch" {
      if ($2 == 1) print "info\tMono\tAlready a mono file"
      else         print "info\t" $2 " channels\tNot a stereo file"
      exit
    }
    $1 == "st" {
      keepl = "Convert to mono (keep the left channel"; keepr = "Convert to mono (keep the right channel"
      l = db($2); r = db($3); d = db($4); s = db($5)
      thr = 20 * log(steps / 2 ^ (bits - 1)) / log(10); if (thr > -60) thr = -60
      if (l <= -1000 && r <= -1000) { print "info\tSilent\tBoth channels are silent"; exit }
      if (d <= -1000) { print "fake\t100% Mono\tMono file disguised as a stereo file\t\t0"; exit }
      if (d <= thr) { print "fake\t100% Mono\tMono file disguised as a stereo file, apart from an inaudible dither noise\t\t0"; exit }
      if (s <= thr) { print "opt\tFake Mono\tMono signal, one channel with inverted polarity\t" keepl ")\t0"; exit }
      if (r <= -1000) { print "opt\tLeft channel only\tThe right channel is silent\t" keepl ")\t0"; exit }
      if (l <= -1000) { print "opt\tRight channel only\tThe left channel is silent\t" keepr ")\t1"; exit }
      rl = lin($6); rr = lin($7); rd = lin($8); rs = lin($9)
      rho = (rl > 0 && rr > 0) ? (rs * rs - rd * rd) / (4 * rl * rr) : 0
      res = 1 - rho * rho; if (res < 1e-30) res = 1e-30
      bal = db($6) - db($7)
      below = (db($6) > db($7) ? db($6) : db($7)) - db($8)   # difference vs. signal (RMS)
      # 99.9% Mono: the difference stays at least 40 dB under the signal (1% in level)
      if (10 * log(res) / log(10) <= -50) {
        if (rho < 0) print "opt\tFake Mono\tMono signal, one channel with inverted polarity\t" keepl ")\t0"
        else if (abs(bal) >= 0.1)
          printf "opt\tFake Mono\tMono signal panned to the %s (the %s channel is %.1f dB louder)\t%s\t%d\n", (bal > 0 ? "left" : "right"), (bal > 0 ? "left" : "right"), abs(bal), (bal > 0 ? keepl ", the louder one)" : keepr ", the louder one)"), (bal > 0 ? 0 : 1)
        else printf "opt\t99.9%% Mono\tPractically mono: the difference between the channels is %.0f dB below the signal\t%s)\t0\n", below, keepl
        exit
      }
      if (below >= 40) { printf "opt\t99.9%% Mono\tPractically mono: the difference between the channels is %.0f dB below the signal\t%s)\t0\n", below, keepl; exit }
      print "info\tReal stereo\t"
      exit
    }
    { print "err" }')
  if [[ -z $out || $out == err ]]; then
    specs+=("${name}"$'\n'"!Not an audio file, or unreadable"); spec_file+=(0)
    continue
  fi
  fld=("${(@ps:\t:)out}")
  # Several files: mono, real stereo, silent or multichannel files are left out
  if (( batch )) && [[ ${fld[1]} == info ]]; then
    case ${fld[2]} in
      Mono)          (( n_mono++ )) ;;
      "Real stereo") (( n_stereo++ )) ;;
      *)             (( n_other++ )) ;;
    esac
    continue
  fi
  # lines: name / result (framed) / detail / checkbox title (optional conversion)
  specs+=("${name}"$'\n'"${fld[2]}"$'\n'"${fld[3]}"$'\n'"${fld[4]}")
  spec_file+=($n)
  keep[n]=${fld[5]:-0}
  case ${fld[1]} in
    fake) todo+=($n) ;;
    opt)  (( nopt++ )) ;;
  esac
done

# --- 3. Window -----------------------------------------------------------------------
# Stereo and mono files found, for information (several files selected)
hidden=()
(( n_stereo )) && hidden+=("$(plural $n_stereo "stereo file")")
(( n_mono ))   && hidden+=("$(plural $n_mono "mono file")")
count=${#todo}
if (( count > 0 && nopt > 0 )); then
  if (( count == 1 )); then summary="1 file is 100% mono and will be converted, plus the ones you tick"
  else summary="${count} files are 100% mono and will be converted, plus the ones you tick"; fi
elif (( count == 1 )); then
  summary="1 file is 100% mono and can be converted to mono"
elif (( count > 1 )); then
  summary="${count} files are 100% mono and can be converted to mono"
elif (( nopt > 0 )); then
  summary="Tick the files you want to convert to mono"
else
  summary="All good, no hidden mono file found!"
fi
(( ${#hidden} )) && summary+=$'\n'"(${(j:, :)hidden})"
if (( count + nopt == 1 )); then
  over_text="Overwrite: replace the original file with a mono file. This cannot be undone."
  dup_text="Duplicate: create a mono copy in a “${copydir}” subfolder, next to the original."
elif (( count + nopt > 1 )); then
  over_text="Overwrite: replace the original files with mono files. This cannot be undone."
  dup_text="Duplicate: create mono copies in a “${copydir}” subfolder, next to the originals."
else
  over_text="" dup_text=""
fi

/usr/bin/base64 --decode > "$tmpdir/icon.png" 2>/dev/null <<'ICON'
iVBORw0KGgoAAAANSUhEUgAAAQAAAAEACAYAAABccqhmAAEAAElEQVR42uy9d5hkV3H+/znnps49
3ZNnNmdtUM5IQggUABEMSASbYIwTJgf764QkLIxtwIDBgAkGbEwQIiogIYRyDrta7WpznJ2dPNO5
+6Zzfn/c7tnZ1UpaiSDsX9fzzLOzM9093feeU6fqrbfegra1rW1ta1vb2ta2trWtbW1rW9va1ra2
ta1tbWtb29rWtra1rW1ta1vb2ta2trWtbW1rW9va1ra2ta1tbWtb29rWtra1rW1ta1vb2ta2trWt
bW1rW9va1ra2ta1tbWtb29rWtra1rW1ta1vb2ta2trWtbW1rW9va1ra2ta1tbWtb29rWtra1rW1t
a1vb2ta2trWtbW1rW9va1ra2ta1tbWtb29rWtra1rW1ta1vb2ta2trWtbW1rW9va1ra2ta1tbWtb
29rWtra1rW1ta1vb2ta2trWtbW1rW9va1ra2ta1tbWtb29rWtra17f+kifYlODbTWovW9fr+978v
Lr/8cgXop3m8BcjmY7LVamGwHgSW7/sEfnDogXO+xWz+Y5lYFoBFwrJ0IpEtAAebj1ZCiOBof/OK
K66Qa9asEZdddpkGtBBCt+9c29oO4Ffc8E+1mbTWJtBbLpczhUahJ3C9E3zfJ1Rhbyg5UakwEYah
EogOhJwHylJKCXTrlQVaawQgDAPZfF2lQQqBFEILQKMLCDGUEGYohagr9HoUk/F4YsI0jU3pdOd0
PB4fOZpjuEJfIa/kStoOoW1tB3CMm/5KruQqcZU64ncO1PtGJ6eWVGu15WGoTiQMV/ihWgB0BQSx
uOPEhRQEWoEQIEAg0GhUqEDr1msBAiGaDkCAlPKIW6Kj8CLyAJimiY0EHT1fSkG9XkdDSQhjUsBO
w7AeEIaxx7GdLR29HbvTIj3+FE6t7Qza1nYAT7cptNZx1y3NOzA+sVYH4elBGJ7qB94KlOq2HCMu
TQM0KKXQWqMAHSqFiGJ+qQ5tXgCFPuxaCyGQUjadwaGfHfb/OS8hEFqJ5s+azkKgpTQkUkikIUEL
wlDhB17ZkHLIMKzNpozf5xjWo/39/RuEEMW5b6H52dvOoO0A/v+66YUWgrmbvnt4eN/xtdA71fO9
l4ZhsFKHus9xbKSQhGFIEIQIoRVCt3Zm6/UQQogj/g4w93Q/tNGf9Y2a85zZ7zVaoxFC6CiSECil
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
T/f4ByfHJzcWCuaSSKTCV1/XRF1dNZqmOOfOn+PMmVNKJqvTPqudtrYWvF4VVdUwDJvyWJRtr26n
t6uXTG4Er39alSgds+QFEAr4/xQl9jdPPPGE8349/O4jgMu7OhmYKrxJplqKpceGzxSBXcCu7u6t
3z18fGj18PDEDV29+zd0ntbmVVfXKS0trcyZM1+OJYadPfvfFql0Qqxbv14U8gVs2wIhGBgYwuv1
YqcMVMWHZVs4EqmgKlI6g5FQ9O0HfvyE/X6/JN0MwOU99oiA2LKlFAwuzwxOdD9Xe+LQwPrB/oEP
pZLFDwiCLY1N9cxonoE/GMKRtmNZpjSKuigrrxDf+9u/pyYeY2DwDP5gQOaKeWkapmoXdLssGv2z
n/7Xb35bbNhgv59vfzcAuLzn6wX8Uo8wfVD3HXuytev02MbensHrkpOZRYoWaG1padUqa+JEouUc
PXyKfXt2U1UZZny8F1X1UMjl0XVzNFYW+Nbdn777Hzdtuif3n+I5y/0YubyfgsE71qoxmj1Q9+LP
9q/oPHvhA+lsttUwjNkjI6PlDbU10dHRATsYVtOWaSf8Xv+BpoaZP/qL//G3uy47G9INAC4u7zEu
WZ1dPl9wiZ///P66tsbWyNatT88CUdRUf3fz7NbMPfd8cfQdZ0K6r6SLi4uLi4uLi4uLi4uLi4uL
i4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uL
i4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uL
i4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uLy3uW/xelrsbi0etWdgAAAABJ
RU5ErkJggg==
ICON

# The window is a native alert, so that the text can use colors and bold:
# AppleLoopEditor's coral red (logoRed) and vintage yellow (vintageYellow).
cat > "$tmpdir/dialog.applescript" <<'APPLESCRIPT'
use AppleScript version "2.4"
use framework "Foundation"
use framework "AppKit"
use scripting additions

property centerValue : 1
property centeredStyle : missing value
property redColor : missing value
property yellowColor : missing value
property logo : missing value
property lastHeight : 0
property optionBoxes : {}
property windowShown : false
property allBox : missing value

-- Arguments: icon, summary, Overwrite text, Duplicate text (both empty when there
-- is nothing to convert), then one result block per file.
-- Returns "Overwrite" | "Duplicate" & linefeed & the numbers of the ticked files,
-- or "" (Cancel / OK)
on run argv
	set iconPath to item 1 of argv
	set summaryText to item 2 of argv
	set overText to item 3 of argv
	set dupText to item 4 of argv
	if (count of argv) > 4 then
		set fileSpecs to items 5 thru -1 of argv
	else
		set fileSpecs to {}
	end if
	activate
	try
		my setupStyle(iconPath)
		set answer to my showWindow(fileSpecs, summaryText, overText, dupText)
	on error errMsg number errNum
		-- the standard dialog only replaces a window that could not be shown
		if errNum is -128 or my windowShown then return ""
		set answer to my plainWindow(fileSpecs, summaryText, overText, dupText)
	end try
	return answer
end run

-- Fallback: the standard dialog, without colors
on plainWindow(fileSpecs, summaryText, overText, dupText)
	set msg to ""
	repeat with spec in fileSpecs
		set lns to paragraphs of (spec as text)
		set msg to msg & (item 1 of lns) & ": "
		if (item 2 of lns) starts with "!" then
			set msg to msg & (text 2 thru -1 of (item 2 of lns))
		else
			set msg to msg & (item 2 of lns)
		end if
		set msg to msg & linefeed
	end repeat
	set msg to msg & linefeed & summaryText
	try
		if overText is "" then
			display dialog msg with title "Find Mono" buttons {"OK"} default button "OK"
			return ""
		end if
		set d to display dialog (msg & linefeed & linefeed & overText & linefeed & linefeed & dupText) with title "Find Mono" buttons {"Overwrite", "Duplicate", "Cancel"} default button "Overwrite" cancel button "Cancel"
	on error
		return ""
	end try
	return (button returned of d) & linefeed
end plainWindow

on setupStyle(iconPath)
	set ca to current application
	set my redColor to ca's NSColor's colorWithSRGBRed:0.94 green:0.58 blue:0.47 alpha:1.0
	set my yellowColor to ca's NSColor's colorWithSRGBRed:0.78 green:0.72 blue:0.48 alpha:0.85
	-- NSTextAlignmentCenter is 1 on Apple Silicon and 2 on Intel Macs
	if (do shell script "/usr/bin/uname -m") is "x86_64" then
		set my centerValue to 2
	else
		set my centerValue to 1
	end if
	set paraStyle to ca's NSMutableParagraphStyle's alloc()'s init()
	paraStyle's setAlignment:(my centerValue)
	set my centeredStyle to paraStyle
	set img to ca's NSImage's alloc()'s initWithContentsOfFile:iconPath
	if img is missing value then set img to ca's NSImage's alloc()'s initWithSize:{1, 1}
	set my logo to img
end setupStyle

on pickFont(isBold, theSize)
	set ca to current application
	if isBold then return ca's NSFont's boldSystemFontOfSize:theSize
	return ca's NSFont's systemFontOfSize:theSize
end pickFont

on addRun(body, theText, theFont, theColor)
	set ca to current application
	set attrs to ca's NSDictionary's dictionaryWithObjects:{theFont, theColor, my centeredStyle} forKeys:{ca's NSFontAttributeName, ca's NSForegroundColorAttributeName, ca's NSParagraphStyleAttributeName}
	body's appendAttributedString:(ca's NSAttributedString's alloc()'s initWithString:theText attributes:attrs)
end addRun

-- Centered text, bold or regular
on lineLabel(theText, isBold, theSize, theColor, textWidth)
	set ca to current application
	set body to ca's NSMutableAttributedString's alloc()'s init()
	my addRun(body, theText, my pickFont(isBold, theSize), theColor)
	return my makeLabel(body, textWidth)
end lineLabel

-- "Label: explanation" -> "Label:" in bold, the rest in regular weight
on explanation(theText, theSize, textWidth)
	set cutPos to offset of ": " in theText
	set ca to current application
	set body to ca's NSMutableAttributedString's alloc()'s init()
	my addRun(body, text 1 thru cutPos of theText, my pickFont(true, theSize), my yellowColor)
	my addRun(body, text (cutPos + 1) thru -1 of theText, my pickFont(false, theSize), my yellowColor)
	return my makeLabel(body, textWidth)
end explanation

-- Wrapping, centered label of the given width
on makeLabel(body, textWidth)
	set ca to current application
	set field to ca's NSTextField's labelWithAttributedString:body
	field's setAlignment:(my centerValue)
	field's setLineBreakMode:0
	field's setMaximumNumberOfLines:0
	field's setPreferredMaxLayoutWidth:textWidth
	(field's cell())'s setWraps:true
	set fitSize to field's fittingSize()
	try
		set textHeight to height of fitSize
	on error
		set textHeight to item 2 of fitSize
	end try
	field's setFrame:{{0, 0}, {textWidth, textHeight}}
	set my lastHeight to textHeight
	return field
end makeLabel

-- Puts a rounded frame around a one-line label (the Loudness result)
on framedLabel(field, fieldHeight, textWidth)
	set ca to current application
	set padX to 18
	set padY to 6
	set textW to textWidth * 0.6
	try
		set probe to ca's NSTextField's labelWithAttributedString:(field's attributedStringValue())
		set fit to probe's fittingSize()
		try
			set textW to width of fit
		on error
			set textW to item 1 of fit
		end try
	end try
	set boxW to textW + 2 * padX
	if boxW > textWidth then set boxW to textWidth
	set wrapH to fieldHeight + 2 * padY
	set wrapper to ca's NSView's alloc()'s initWithFrame:{{0, 0}, {textWidth, wrapH}}
	set optBox to ca's NSBox's alloc()'s initWithFrame:{{(textWidth - boxW) / 2, 0}, {boxW, wrapH}}
	optBox's setBoxType:4 -- custom
	optBox's setTitlePosition:0 -- no title
	optBox's setBorderWidth:1.5
	optBox's setCornerRadius:8
	optBox's setBorderColor:((ca's NSColor's labelColor())'s colorWithAlphaComponent:0.55)
	optBox's setFillColor:((ca's NSColor's labelColor())'s colorWithAlphaComponent:0.06)
	wrapper's addSubview:optBox
	field's setFrameOrigin:{0, padY}
	wrapper's addSubview:field
	set my lastHeight to wrapH
	return wrapper
end framedLabel

-- Stacks views top to bottom, each one centered horizontally (AppKit's y axis goes up)
on stackViews(theViews, theHeights, theWidths, gap, outerWidth)
	set ca to current application
	set total to 0
	repeat with h in theHeights
		set total to total + h
	end repeat
	set total to total + gap * ((count of theHeights) - 1)
	set container to ca's NSView's alloc()'s initWithFrame:{{0, 0}, {outerWidth, total}}
	set y to total
	repeat with k from 1 to count of theViews
		set y to y - (item k of theHeights)
		((item k of theViews)'s setFrameOrigin:{(outerWidth - (item k of theWidths)) / 2, y})
		container's addSubview:(item k of theViews)
		set y to y - gap
	end repeat
	set my lastHeight to total
	return container
end stackViews

-- Button frames tell which layout NSAlert chose: stacked buttons (the centered
-- layout) or side by side (the old layout, used when the window is too tall).
on buttonY(b)
	set r to b's frame()
	try
		return y of origin of r
	on error
		return item 2 of item 1 of r
	end try
end buttonY

on isCentered(theAlert)
	set theButtons to theAlert's buttons()
	set y1 to my buttonY(theButtons's objectAtIndex:0)
	set y2 to my buttonY(theButtons's objectAtIndex:1)
	return (y1 - y2 > 1 or y2 - y1 > 1)
end isCentered

-- One file: name / result (framed) / detail / "Convert to mono" box (optional)
on fileBlock(spec, textWidth, specIndex)
	set ca to current application
	set lns to paragraphs of spec
	set parts to {}
	set heights to {}
	set end of parts to my lineLabel(item 1 of lns, true, 15, my yellowColor, textWidth)
	set end of heights to my lastHeight
	if (item 2 of lns) starts with "!" then
		set end of parts to my lineLabel(text 2 thru -1 of (item 2 of lns), false, 14, my yellowColor, textWidth)
		set end of heights to my lastHeight
	else
		set end of parts to my framedLabel(my lineLabel(item 2 of lns, true, 18, ca's NSColor's labelColor(), textWidth), my lastHeight, textWidth)
		set end of heights to my lastHeight
		if (count of lns) > 2 and (item 3 of lns) is not "" then
			set end of parts to my lineLabel(item 3 of lns, false, 14, my yellowColor, textWidth)
			set end of heights to my lastHeight
		end if
	end if
	set widths to {}
	repeat with k from 1 to count of parts
		set end of widths to textWidth
	end repeat
	if (count of lns) > 3 and (item 4 of lns) is not "" then
		set optBox to ca's NSButton's checkboxWithTitle:(item 4 of lns) target:(missing value) action:(missing value)
		set attrs to ca's NSDictionary's dictionaryWithObjects:{my pickFont(false, 13), my yellowColor} forKeys:{ca's NSFontAttributeName, ca's NSForegroundColorAttributeName}
		optBox's setAttributedTitle:(ca's NSAttributedString's alloc()'s initWithString:(item 4 of lns) attributes:attrs)
		optBox's setState:0
		optBox's setRefusesFirstResponder:true -- Return stays on the default button
		set fit to optBox's fittingSize()
		try
			set boxWidth to width of fit
		on error
			set boxWidth to item 1 of fit
		end try
		if boxWidth > textWidth then set boxWidth to textWidth
		optBox's setFrame:{{0, 0}, {boxWidth, 22}}
		set end of parts to optBox
		set end of heights to 22
		set end of widths to boxWidth
		set end of my optionBoxes to {specIndex, optBox}
	end if
	return my stackViews(parts, heights, widths, 6, textWidth)
end fileBlock

-- Results of every file, in a scroll view of the same width when too tall
on resultsView(fileSpecs, textWidth, maxHeight)
	set ca to current application
	repeat with w in {textWidth, textWidth - 20}
		set my optionBoxes to {}
		set blocks to {}
		set heights to {}
		set widths to {}
		repeat with k from 1 to count of fileSpecs
			set end of blocks to my fileBlock((item k of fileSpecs) as text, contents of w, k)
			set end of heights to my lastHeight
			set end of widths to contents of w
		end repeat
		set listView to my stackViews(blocks, heights, widths, 26, contents of w)
		set h to my lastHeight
		if h <= maxHeight then return {listView, h}
	end repeat
	set scroller to ca's NSScrollView's alloc()'s initWithFrame:{{0, 0}, {textWidth, maxHeight}}
	scroller's setHasVerticalScroller:true
	scroller's setDrawsBackground:false
	scroller's setBorderType:0
	scroller's setDocumentView:listView
	(scroller's contentView())'s scrollToPoint:{0, h - maxHeight}
	scroller's reflectScrolledClipView:(scroller's contentView())
	return {scroller, maxHeight}
end resultsView

-- "Tick all" box clicked: every file box takes its state
on tickAll:sender
	set newState to (sender's state()) as integer
	repeat with ob in my optionBoxes
		set fileBox to item 2 of (contents of ob)
		fileBox's setState:newState
	end repeat
end tickAll:

-- A file box clicked: "Tick all" is ticked only while every file box is
on boxTicked:sender
	if my allBox is missing value then return
	set allOn to 1
	repeat with ob in my optionBoxes
		set fileBox to item 2 of (contents of ob)
		if ((fileBox's state()) as integer) = 0 then set allOn to 0
	end repeat
	(my allBox)'s setState:allOn
end boxTicked:

on buildAlert(fileSpecs, summaryText, overText, dupText, maxHeight)
	set ca to current application
	set textWidth to 440
	-- Title, drawn here in red (NSAlert's own title cannot be colored)
	set titleLabel to my lineLabel("Find Mono", true, 18, my redColor, textWidth)
	set titleHeight to my lastHeight
	-- Summary in red (white when all is good); the file counts under it (second line) in yellow
	set body to ca's NSMutableAttributedString's alloc()'s init()
	set summaryColor to my redColor
	if (paragraph 1 of summaryText) starts with "All good" then set summaryColor to ca's NSColor's labelColor()
	my addRun(body, paragraph 1 of summaryText, my pickFont(true, 16), summaryColor)
	if (count of paragraphs of summaryText) > 1 then
		my addRun(body, linefeed & (paragraph 2 of summaryText), my pickFont(false, 14), my yellowColor)
	end if
	set summaryLabel to my makeLabel(body, textWidth)
	set summaryHeight to my lastHeight
	set my allBox to missing value
	if (count of fileSpecs) > 0 then
		set results to my resultsView(fileSpecs, textWidth, maxHeight)
		set theViews to {titleLabel, item 1 of results, summaryLabel}
		set theHeights to {titleHeight, item 2 of results, summaryHeight}
		set theWidths to {textWidth, textWidth, textWidth}
		-- Several boxes: one more box, under the summary, ticks or unticks them all
		set boxCount to count of my optionBoxes
		if boxCount > 1 then
			set allTitle to "Tick all " & boxCount & " files"
			set newBox to ca's NSButton's checkboxWithTitle:allTitle target:(missing value) action:(missing value)
			newBox's setTarget:me
			newBox's setAction:"tickAll:"
			set attrs to ca's NSDictionary's dictionaryWithObjects:{my pickFont(true, 14), ca's NSColor's labelColor()} forKeys:{ca's NSFontAttributeName, ca's NSForegroundColorAttributeName}
			newBox's setAttributedTitle:(ca's NSAttributedString's alloc()'s initWithString:allTitle attributes:attrs)
			newBox's setState:0
			newBox's setRefusesFirstResponder:true -- Return stays on the default button
			set fit to newBox's fittingSize()
			try
				set boxWidth to width of fit
			on error
				set boxWidth to item 1 of fit
			end try
			if boxWidth > textWidth then set boxWidth to textWidth
			newBox's setFrame:{{0, 0}, {boxWidth, 22}}
			repeat with ob in my optionBoxes
				set fileBox to item 2 of (contents of ob)
				fileBox's setTarget:me
				fileBox's setAction:"boxTicked:"
			end repeat
			set my allBox to newBox
			set end of theViews to newBox
			set end of theHeights to 22
			set end of theWidths to boxWidth
		end if
	else
		-- nothing to list (several files, all of them real stereo or mono)
		set theViews to {titleLabel, summaryLabel}
		set theHeights to {titleHeight, summaryHeight}
		set theWidths to {textWidth, textWidth}
	end if
	if overText is not "" then
		set overLabel to my explanation(overText, 13, textWidth)
		set overHeight to my lastHeight
		set dupLabel to my explanation(dupText, 13, textWidth)
		set dupHeight to my lastHeight
		set end of theViews to my stackViews({overLabel, dupLabel}, {overHeight, dupHeight}, {textWidth, textWidth}, 8, textWidth)
		set end of theHeights to my lastHeight
		set end of theWidths to textWidth
	end if
	set accessory to my stackViews(theViews, theHeights, theWidths, 20, textWidth)

	set theAlert to ca's NSAlert's alloc()'s init()
	theAlert's setMessageText:""
	theAlert's setInformativeText:""
	theAlert's setIcon:(my logo)
	theAlert's setAccessoryView:accessory
	if overText is "" then
		set okButton to theAlert's addButtonWithTitle:"OK"
		okButton's setKeyEquivalent:(character id 13)
	else
		-- Buttons, top to bottom: Overwrite (default, Return), Duplicate, Cancel (Esc)
		set overButton to theAlert's addButtonWithTitle:"Overwrite"
		set dupButton to theAlert's addButtonWithTitle:"Duplicate"
		set cancelButton to theAlert's addButtonWithTitle:"Cancel"
		overButton's setKeyEquivalent:(character id 13)
		dupButton's setKeyEquivalent:""
		cancelButton's setKeyEquivalent:(character id 27)
	end if
	return theAlert
end buildAlert

on showWindow(fileSpecs, summaryText, overText, dupText)
	set ca to current application
	if my centeredStyle is missing value then error "style not ready"
	-- The list gets shorter until the window fits with the centered layout
	repeat with maxHeight in {360, 300, 250, 200, 160, 130}
		set theAlert to my buildAlert(fileSpecs, summaryText, overText, dupText, contents of maxHeight)
		theAlert's layout()
		if overText is "" then exit repeat -- a single button: nothing to compare
		if my isCentered(theAlert) then exit repeat
	end repeat
	-- osascript runs in the background: as an accessory app it may come to the front
	try
		ca's NSApplication's sharedApplication()'s setActivationPolicy:1
	end try
	-- Floating level: the window stays above the Finder windows
	try
		(theAlert's |window|())'s setLevel:3
	end try
	ca's NSApplication's sharedApplication()'s activateIgnoringOtherApps:true
	set my windowShown to true
	set response to (theAlert's runModal()) as integer
	if overText is "" or response > 1001 then return ""
	set ticked to ""
	repeat with ob in my optionBoxes
		set ob to contents of ob
		set optBox to item 2 of ob
		if ((optBox's state()) as integer) = 1 then set ticked to ticked & ((item 1 of ob) as text) & " "
	end repeat
	if response = 1000 then return "Overwrite" & linefeed & ticked
	if response = 1001 then return "Duplicate" & linefeed & ticked
	return ""
end showWindow
APPLESCRIPT

answer=$(/usr/bin/osascript "$tmpdir/dialog.applescript" "$tmpdir/icon.png" "$summary" \
  "$over_text" "$dup_text" "${specs[@]}" 2>/dev/null)
case ${answer%%$'\n'*} in
  Overwrite) mode=overwrite ;;
  Duplicate) mode=duplicate ;;
  *)         exit 0 ;;
esac
# Ticked files (entry numbers in the window) join the fake stereo files
if [[ $answer == *$'\n'* ]]; then
  for i in ${=${answer#*$'\n'}}; do
    [[ $i == <-> ]] && (( i >= 1 && i <= ${#spec_file} && spec_file[i] > 0 )) && todo+=(${spec_file[i]})
  done
fi
count=${#todo}
if (( count == 0 )); then
  notify "Find Mono" "No file converted"
  exit 0
fi

# --- 4. Convert, several files at a time ---------------------------------------------
pids=()
for n in "${todo[@]}"; do
  f=${files[n]}
  name=${f##*/}
  dir=${f%/*}; [[ -n $dir ]] || dir=/
  if [[ $mode == duplicate ]]; then
    if ! [[ -d $dir/$copydir ]] && ! mkdir -p "$dir/$copydir"; then
      print -r -- "err could not create the “${copydir}” folder" > "$tmpdir/$n.res"
      continue
    fi
    out="$dir/$copydir/$name"
  else
    out=$f
  fi
  part="${out%/*}/.${name}.mono-part"
  info=(${=infos[n]})
  if [[ ${info[1]} == pcm ]]; then
    mono_pcm_job $n "$f" "$out" "$part" "${keep[n]:-0}" &
  else
    mono_flac_job $n "$f" "$out" "$part" "${info[2]}" "${info[3]}" "${keep[n]:-0}" &
  fi
  pids+=($!)
  if (( ${#pids} >= maxjobs )); then wait ${pids[1]}; shift pids; fi
done
wait

# --- 5. Summary ------------------------------------------------------------------------
done_count=0
errors=""
for n in "${todo[@]}"; do
  r=""
  [[ -f $tmpdir/$n.res ]] && r=$(<"$tmpdir/$n.res")
  case $r in
    ok)     (( done_count++ )) ;;
    err\ *) errors+="${labels[n]}: ${r#err }"$'\n' ;;
    *)      errors+="${labels[n]}: unknown error"$'\n' ;;
  esac
done
result="$(plural $done_count file) converted to mono"
(( done_count == 0 )) && result="No file converted"
[[ $mode == duplicate ]] && (( done_count > 0 )) && result+=" → “${copydir}” folder"
if [[ -n $errors ]]; then
  alert "$result" "Errors:"$'\n'"${errors}"
else
  notify "Find Mono" "$result"
fi

exit 0
