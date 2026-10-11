#!/bin/zsh
# Peak Normalize — macOS Finder Quick Action that peak-normalizes lossless audio files.
#
# - Asks for the target peak level, then whether to overwrite the original files
#   or duplicate them into a "Normalized" subfolder of the source folder.
# - Lossless formats only: WAV, AIFF/AIF/AIFC, CAF (uncompressed PCM) and FLAC.
#   Lossy files (MP3, AAC/M4A...) are skipped.
# - File type, bit depth (8/16/24/32-bit, integer or float) and sample rate are kept.
# - Files already at the requested level are not re-processed (only their date is updated).
# - WAV / AIFF / CAF: the result is a byte-for-byte copy of the original in which only
#   the audio samples are replaced, so Apple Loops metadata (tempo, key, tags,
#   transients), markers, ID3 tags, Finder tags and Spotlight comments are preserved.
# - FLAC: re-encoded to FLAC with ffmpeg, keeping tags and cover art.
# - Several files are processed in parallel.
#
# Requires sox (WAV/AIFF/CAF) and ffmpeg (FLAC only). Runs with /bin/zsh.

levels=(0 -0.1 -0.2 -0.5 -1)   # target peak levels offered, in dBFS
default_level=0
tolerance=0.01                 # dB: files this close to the target are left as is
copydir="Normalized"           # subfolder used by "Duplicate"

export LC_NUMERIC=C

# A native (Homebrew) sox is preferred: the standalone 2015 build is Intel-only
# and runs through Rosetta on Apple Silicon.
SOX="" FFMPEG=""
for p in /opt/homebrew/bin/sox /usr/local/bin/sox /Applications/sox/sox; do
  [[ -x $p ]] && { SOX=$p; break; }
done
for p in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
  [[ -x $p ]] && { FFMPEG=$p; break; }
done

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/peaknorm.XXXXXX") || exit 1
trap 'rm -rf "$tmpdir"' EXIT
pl="$tmpdir/afmeta.pl"

# --- File structure helper -------------------------------------------------------
#   scan FILE...                 one line per file: "pcm ENC BITS ENDIAN OFFSET LENGTH
#                                CHANNELS RATE", "flac BITS RATE", "lossy",
#                                "compressed", "unreadable" or "none"
#   extract FILE OFFSET LENGTH   writes the audio bytes to stdout
#   splice FILE OFFSET LENGTH RAW  overwrites the audio bytes with RAW (same size)
#   flacinfo FILE                prints "BITS RATE"
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

# --- Jobs ------------------------------------------------------------------------
# Each job runs in the background and writes one line to $tmpdir/<n>.res:
#   "ok", "same" (already at the requested level) or "err <message>".

# The audio is not touched, but the modification date is set to now, like for
# the files that were normalized.
keep_as_is() {   # src out partial res — file already at the requested level
  if [[ $mode == duplicate ]]; then
    if ! { cp -p "$1" "$3" && touch "$3" && mv -f "$3" "$2"; }; then
      rm -f "$3"; print -r -- "err could not copy the file" > "$4"; return
    fi
  else
    touch "$1"
  fi
  print same > "$4"
}

# WAV / AIFF / CAF. A single sox run measures the peak ("stat") and renders the
# normalized samples ("--norm") as raw audio in exactly the original sample format;
# they are then written over the audio data of an exact copy of the original.
pcm_job() {   # n src out partial enc bits endian offset length channels rate
  local n=$1 src=$2 out=$3 part=$4 off=$8 len=$9
  local raw="$tmpdir/$n.raw" st="$tmpdir/$n.stat" res="$tmpdir/$n.res" verdict
  local -a fmt
  fmt=(-t raw -e "$5" -b "$6" "-$7")

  [[ -n $SOX ]] || { print -r -- "err sox not found" > "$res"; return; }
  if ! /usr/bin/perl "$pl" extract "$src" "$off" "$len" \
     | "$SOX" -V1 --norm="$level" "${fmt[@]}" -c "${10}" -r "${11}" - "${fmt[@]}" "$raw" \
         stat 2> "$st"; then
    rm -f "$raw"; print -r -- "err sox failed" > "$res"; return
  fi

  verdict=$(awk -v t="$level" -v tol="$tolerance" '
    /^Maximum amplitude/ { mx = $3; seen = 1 }
    /^Minimum amplitude/ { mn = $3 }
    END {
      if (!seen) { print "err"; exit }
      a = mx < 0 ? -mx : mx; b = mn < 0 ? -mn : mn; p = a > b ? a : b
      if (p <= 0) { print "silent"; exit }
      d = t - 20 * log(p) / log(10); if (d < 0) d = -d
      print (d < tol ? "same" : "change")
    }' "$st")

  case $verdict in
    change) ;;
    same)   rm -f "$raw"; keep_as_is "$src" "$out" "$part" "$res"; return ;;
    silent) rm -f "$raw"; print -r -- "err silent file" > "$res"; return ;;
    *)      rm -f "$raw"; print -r -- "err could not measure the level" > "$res"; return ;;
  esac

  if ! cp -p "$src" "$part"; then
    rm -f "$raw"; print -r -- "err could not write the file" > "$res"; return
  fi
  if ! /usr/bin/perl "$pl" splice "$part" "$off" "$len" "$raw"; then
    rm -f "$raw" "$part"; print -r -- "err unexpected file structure" > "$res"; return
  fi
  rm -f "$raw"
  if mv -f "$part" "$out"; then
    print ok > "$res"
  else
    rm -f "$part"; print -r -- "err could not write the file" > "$res"
  fi
}

# Peak of a FLAC file, compared with the target:
#   "same" | "silent" | "change <gain dB>" | "err"
flac_verdict() {
  local v af
  for af in astats=measure_perchannel=none:measure_overall=Peak_level astats; do
    v=$("$FFMPEG" -nostdin -hide_banner -nostats -i "$1" -map 0:a:0 -af "$af" -f null - 2>&1 \
      | awk -v t="$level" -v tol="$tolerance" '
          /Peak level dB/ { p = $NF; seen = 1 }
          END {
            if (!seen) { print "err"; exit }
            if (p ~ /inf/) { print "silent"; exit }
            d = t - p; a = d < 0 ? -d : d
            if (a < tol) print "same"; else printf "change %.6f\n", d
          }')
    [[ $v != err ]] && break
  done
  print -r -- "$v"
}

# FLAC: decode, apply gain, re-encode to FLAC with the same bit depth and sample
# rate; the result is checked before it is kept.
flac_job() {   # n src out partial bits rate
  local n=$1 src=$2 out=$3 part=$4 bits=$5 rate=$6
  local enc="$tmpdir/$n.flac" res="$tmpdir/$n.res" verdict conv
  local -a fmt

  [[ -n $FFMPEG ]] || { print -r -- "err ffmpeg not found (required for FLAC)" > "$res"; return; }
  case $bits in
    16) fmt=(-sample_fmt s16); conv="aresample=osf=s16:dither_method=triangular" ;;
    24) fmt=(-sample_fmt s32 -bits_per_raw_sample 24); conv="aresample=osf=s32" ;;
    32) fmt=(-sample_fmt s32 -bits_per_raw_sample 32 -strict experimental); conv="aresample=osf=s32" ;;
    *)  print -r -- "err unsupported FLAC bit depth (${bits}-bit)" > "$res"; return ;;
  esac

  verdict=$(flac_verdict "$src")
  case $verdict in
    change\ *) ;;
    same)   keep_as_is "$src" "$out" "$part" "$res"; return ;;
    silent) print -r -- "err silent file" > "$res"; return ;;
    *)      print -r -- "err could not measure the level" > "$res"; return ;;
  esac

  if ! "$FFMPEG" -nostdin -v error -y -i "$src" -map 0:a:0 -map '0:v?' -map_metadata 0 \
       -c copy -c:a flac "${fmt[@]}" -ar "$rate" \
       -af "volume=${verdict#change }dB:precision=double,${conv}" "$enc"; then
    rm -f "$enc"; print -r -- "err ffmpeg failed" > "$res"; return
  fi
  if [[ $(/usr/bin/perl "$pl" flacinfo "$enc") != "$bits $rate" ]]; then
    rm -f "$enc"; print -r -- "err bit depth or sample rate changed, file not written" > "$res"; return
  fi
  # cp -p, then overwrite the content: Finder tags / extended attributes are kept
  if cp -p "$src" "$part" && cat "$enc" > "$part" && mv -f "$part" "$out"; then
    print ok > "$res"
  else
    rm -f "$part"; print -r -- "err could not write the file" > "$res"
  fi
  rm -f "$enc"
}

# --- 1. Scan the selection (headers only) ----------------------------------------
files=() infos=()
skipped=""
scan=("${(@f)$(/usr/bin/perl "$pl" scan "$@")}")
for (( i = 1; i <= $#; i++ )); do
  f=${argv[i]}
  case ${scan[i]} in
    pcm\ *|flac\ *) files+=("$f"); infos+=("${scan[i]}") ;;
    lossy)          skipped+="${f##*/}"$'\n' ;;
    compressed)     skipped+="${f##*/} (compressed audio)"$'\n' ;;
    unreadable)     skipped+="${f##*/} (unreadable file)"$'\n' ;;
  esac
done

if (( ${#files} == 0 )); then
  alert "No lossless audio file selected" \
    "Supported formats: WAV, AIFF, CAF, FLAC."$'\n\n'"Skipped:"$'\n'"${skipped}"
  exit 0
fi

# --- 2. Target level, then Overwrite / Duplicate ----------------------------------
if (( ${#files} == 1 )); then
  what="“${files[1]##*/}”"
  over_text="Overwrite: replace the original file. This cannot be undone."
  dup_text="Duplicate: create a normalized copy in a “${copydir}” subfolder, next to the original."
else
  what="$(plural ${#files} file)"
  over_text="Overwrite: replace the original files. This cannot be undone."
  dup_text="Duplicate: create normalized copies in a “${copydir}” subfolder, next to the originals."
fi
head_text="Normalize ${what} to %LEVEL%."
prompt_text="Normalize ${what}"$'\n'"Target peak level:"
level_items=()
for l in "${levels[@]}"; do level_items+=("$l dB"); done

# Logo shown in the alert (PNG, base64)
/usr/bin/base64 --decode > "$tmpdir/icon.png" 2>/dev/null <<'ICON'
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
RABgxHX++gAAAABJRU5ErkJggg==
ICON

# The second window is a native alert, so that the text can use colors and bold:
# AppleLoopEditor's coral red (logoRed) and vintage yellow (vintageYellow).
cat > "$tmpdir/dialog.applescript" <<'APPLESCRIPT'
use AppleScript version "2.4"
use framework "Foundation"
use framework "AppKit"
use scripting additions

property centerValue : 1
property centeredStyle : missing value
property boldFont : missing value
property plainFont : missing value
property redColor : missing value
property yellowColor : missing value
property logo : missing value
property lastHeight : 0

on run argv
	set thePrompt to item 1 of argv
	set headTemplate to item 2 of argv
	set overText to item 3 of argv
	set dupText to item 4 of argv
	set defaultLevel to item 5 of argv
	set iconPath to item 6 of argv
	set levelList to items 7 thru -1 of argv
	activate

	-- 1. Target level
	try
		my setupStyle(iconPath)
		set lvl to my styledLevelDialog(paragraph 1 of thePrompt, paragraph 2 of thePrompt, levelList, defaultLevel)
	on error
		set lvl to my plainLevelDialog(thePrompt, levelList, defaultLevel)
	end try
	if lvl is "" then return ""

	-- 2. Overwrite / Duplicate
	set headText to my replaceText(headTemplate, "%LEVEL%", lvl)
	try
		set choice to my styledActionDialog(headText, overText, dupText)
	on error
		set choice to my plainActionDialog(headText, overText, dupText)
	end try
	if choice is "" then return ""
	return lvl & linefeed & choice
end run

on replaceText(theText, findText, newText)
	set AppleScript's text item delimiters to findText
	set chunks to text items of theText
	set AppleScript's text item delimiters to newText
	set theText to chunks as text
	set AppleScript's text item delimiters to ""
	return theText
end replaceText

-- Fallbacks: the standard dialogs, without colors
on plainLevelDialog(thePrompt, levelList, defaultLevel)
	set picked to choose from list levelList with title "Peak Normalize" with prompt thePrompt default items {defaultLevel} OK button name "Next" cancel button name "Cancel"
	if picked is false then return ""
	return item 1 of picked
end plainLevelDialog

on plainActionDialog(headText, overText, dupText)
	try
		set d to display dialog (headText & linefeed & linefeed & overText & linefeed & linefeed & dupText) with title "Peak Normalize" buttons {"Overwrite", "Duplicate", "Cancel"} default button "Overwrite" cancel button "Cancel"
		return button returned of d
	on error
		return ""
	end try
end plainActionDialog

-- Fonts, AppleLoopEditor colors (logoRed, vintageYellow), centered text, logo
on setupStyle(iconPath)
	set ca to current application
	set fontSize to ca's NSFont's systemFontSize()
	set my boldFont to ca's NSFont's boldSystemFontOfSize:fontSize
	set my plainFont to ca's NSFont's systemFontOfSize:fontSize
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

on addRun(body, theText, theFont, theColor)
	set ca to current application
	set attrs to ca's NSDictionary's dictionaryWithObjects:{theFont, theColor, my centeredStyle} forKeys:{ca's NSFontAttributeName, ca's NSForegroundColorAttributeName, ca's NSParagraphStyleAttributeName}
	body's appendAttributedString:(ca's NSAttributedString's alloc()'s initWithString:theText attributes:attrs)
end addRun

-- "Label: explanation" -> "Label:" in bold, the rest in regular weight
on addLabelled(body, theText, theColor)
	set AppleScript's text item delimiters to ":"
	set theLabel to text item 1 of theText
	set AppleScript's text item delimiters to ""
	my addRun(body, theLabel & ":", my boldFont, theColor)
	my addRun(body, text ((length of theLabel) + 2) thru -1 of theText, my plainFont, theColor)
end addLabelled

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

on newAlert(accessory)
	set ca to current application
	set theAlert to ca's NSAlert's alloc()'s init()
	theAlert's setMessageText:"Peak Normalize"
	theAlert's setInformativeText:""
	theAlert's setIcon:(my logo)
	theAlert's setAccessoryView:accessory
	return theAlert
end newAlert

on styledLevelDialog(headText, questionText, levelList, defaultLevel)
	set ca to current application
	set textWidth to 420
	set body to ca's NSMutableAttributedString's alloc()'s init()
	my addRun(body, headText & linefeed & linefeed, my boldFont, my redColor)
	my addRun(body, questionText, my boldFont, my yellowColor)
	set field to my makeLabel(body, textWidth)
	set labelHeight to my lastHeight

	set popupWidth to 160
	set popup to ca's NSPopUpButton's alloc()'s initWithFrame:{{(textWidth - popupWidth) / 2, 0}, {popupWidth, 28}} pullsDown:false
	popup's addItemsWithTitles:levelList
	popup's selectItemWithTitle:defaultLevel

	set container to ca's NSView's alloc()'s initWithFrame:{{0, 0}, {textWidth, labelHeight + 40}}
	field's setFrameOrigin:{0, 40}
	container's addSubview:field
	container's addSubview:popup

	set theAlert to my newAlert(container)
	set nextButton to theAlert's addButtonWithTitle:"Next"
	set cancelButton to theAlert's addButtonWithTitle:"Cancel"
	nextButton's setKeyEquivalent:(character id 13)
	cancelButton's setKeyEquivalent:(character id 27)
	ca's NSApplication's sharedApplication()'s activateIgnoringOtherApps:true
	set response to (theAlert's runModal()) as integer
	if response is not 1000 then return ""
	return (popup's titleOfSelectedItem()) as text
end styledLevelDialog

on styledActionDialog(headText, overText, dupText)
	set ca to current application
	if my centeredStyle is missing value then error "style not ready"
	set body to ca's NSMutableAttributedString's alloc()'s init()
	my addRun(body, headText & linefeed & linefeed, my boldFont, my redColor)
	my addLabelled(body, overText, my yellowColor)
	my addRun(body, linefeed & linefeed, my plainFont, my yellowColor)
	my addLabelled(body, dupText, my yellowColor)
	set field to my makeLabel(body, 420)

	set theAlert to my newAlert(field)
	-- Buttons, top to bottom: Overwrite (default, Return), Duplicate, Cancel (Esc)
	set overButton to theAlert's addButtonWithTitle:"Overwrite"
	set dupButton to theAlert's addButtonWithTitle:"Duplicate"
	set cancelButton to theAlert's addButtonWithTitle:"Cancel"
	overButton's setKeyEquivalent:(character id 13)
	dupButton's setKeyEquivalent:""
	cancelButton's setKeyEquivalent:(character id 27)
	ca's NSApplication's sharedApplication()'s activateIgnoringOtherApps:true
	set response to (theAlert's runModal()) as integer
	if response = 1000 then return "Overwrite"
	if response = 1001 then return "Duplicate"
	return ""
end styledActionDialog
APPLESCRIPT

answer=$(/usr/bin/osascript "$tmpdir/dialog.applescript" "$prompt_text" "$head_text" \
  "$over_text" "$dup_text" "${default_level} dB" "$tmpdir/icon.png" "${level_items[@]}" 2>/dev/null)
if (( $? != 0 )); then
  # Safety net: if the script above cannot run, use the standard dialogs.
  answer=$(/usr/bin/osascript \
    -e 'on run argv' \
    -e 'activate' \
    -e 'set picked to choose from list (items 4 thru -1 of argv) with title "Peak Normalize" with prompt (item 1 of argv) default items {item 3 of argv} OK button name "Next" cancel button name "Cancel"' \
    -e 'if picked is false then return ""' \
    -e 'set lvl to item 1 of picked' \
    -e 'set AppleScript'"'"'s text item delimiters to "%LEVEL%"' \
    -e 'set chunks to text items of (item 2 of argv)' \
    -e 'set AppleScript'"'"'s text item delimiters to lvl' \
    -e 'set msg to chunks as text' \
    -e 'set AppleScript'"'"'s text item delimiters to ""' \
    -e 'try' \
    -e 'set d to display dialog msg with title "Peak Normalize" buttons {"Overwrite", "Duplicate", "Cancel"} default button "Overwrite" cancel button "Cancel"' \
    -e 'on error' \
    -e 'return ""' \
    -e 'end try' \
    -e 'return lvl & linefeed & (button returned of d)' \
    -e 'end run' \
    "$prompt_text" "${head_text}"$'\n\n'"${over_text}"$'\n\n'"${dup_text}" "${default_level} dB" "${level_items[@]}" \
    2>/dev/null)
fi

[[ $answer == *$'\n'* ]] || exit 0
level=${${answer%%$'\n'*}% dB}
case ${answer#*$'\n'} in
  Overwrite) mode=overwrite ;;
  Duplicate) mode=duplicate ;;
  *)         exit 0 ;;
esac

# --- 3. Normalize, several files at a time ---------------------------------------
maxjobs=$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null)
[[ $maxjobs == <-> ]] || maxjobs=4
(( maxjobs > 6 )) && maxjobs=6
(( maxjobs < 1 )) && maxjobs=1

pids=()
for (( n = 1; n <= ${#files}; n++ )); do
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
  # Hidden temporary file next to the destination: the destination is only
  # replaced once the normalized file is complete.
  part="${out%/*}/.${name}.normalize-part"

  info=(${=infos[n]})
  if [[ ${info[1]} == pcm ]]; then
    pcm_job $n "$f" "$out" "$part" "${(@)info[2,8]}" &
  else
    flac_job $n "$f" "$out" "$part" "${info[2]}" "${info[3]}" &
  fi
  pids+=($!)
  if (( ${#pids} >= maxjobs )); then
    wait ${pids[1]}
    shift pids
  fi
done
wait

# --- 4. Summary ------------------------------------------------------------------
count=0 unchanged=0
errors=""
for (( n = 1; n <= ${#files}; n++ )); do
  r=""
  [[ -f $tmpdir/$n.res ]] && r=$(<"$tmpdir/$n.res")
  case $r in
    ok)     (( count++ )) ;;
    same)   (( unchanged++ )) ;;
    err\ *) errors+="${files[n]##*/}: ${r#err }"$'\n' ;;
    *)      errors+="${files[n]##*/}: unknown error"$'\n' ;;
  esac
done

summary=""
(( count > 0 )) && summary="$(plural $count file) normalized to ${level} dB"
if (( unchanged > 0 )); then
  [[ -n $summary ]] && summary+=", "
  if [[ $mode == duplicate ]]; then
    summary+="$(plural $unchanged file) already at ${level} dB (copied as is)"
  else
    summary+="$(plural $unchanged file) already at ${level} dB (audio unchanged)"
  fi
fi
[[ -n $summary ]] || summary="No file normalized"
[[ $mode == duplicate ]] && (( count + unchanged > 0 )) && summary+=" → “${copydir}” folder"

report=""
[[ -n $errors ]]  && report+="Errors:"$'\n'"${errors}"$'\n'
[[ -n $skipped ]] && report+="Skipped (not a lossless format):"$'\n'"${skipped}"
if [[ -n $report ]]; then
  alert "$summary" "$report"
else
  notify "Peak Normalize" "$summary"
fi

exit 0
