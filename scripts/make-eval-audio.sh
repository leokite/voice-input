#!/bin/bash
# Usage: make-eval-audio.sh <text> <out.pcm> [voice]
# Synthesizes speech with `say` and writes raw 16 kHz mono s16le PCM (no header).
set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: $0 <text> <out.pcm> [voice=Kyoko]" >&2
  exit 64
fi

text="$1"
out="$2"
voice="${3:-Kyoko}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

say -v "$voice" -o "$tmp/speech.aiff" -- "$text"
afconvert -f WAVE -d LEI16@16000 -c 1 "$tmp/speech.aiff" "$tmp/speech.wav"

# afconvert may insert extra chunks (e.g. FLLR), so locate the `data` chunk
# instead of assuming a 44-byte header.
perl -e '
  use strict; use warnings;
  my ($in, $outp) = @ARGV;
  open(my $f, "<:raw", $in) or die "open: $!";
  local $/; my $d = <$f>; close $f;
  die "not a RIFF/WAVE file\n" unless substr($d, 0, 4) eq "RIFF" && substr($d, 8, 4) eq "WAVE";
  my $pos = 12;
  while ($pos + 8 <= length($d)) {
    my $id = substr($d, $pos, 4);
    my $size = unpack("V", substr($d, $pos + 4, 4));
    if ($id eq "data") {
      my $avail = length($d) - ($pos + 8);
      $size = $avail if $size > $avail;
      open(my $o, ">:raw", $outp) or die "open: $!";
      print $o substr($d, $pos + 8, $size);
      close $o;
      exit 0;
    }
    $pos += 8 + $size + ($size % 2);
  }
  die "no data chunk found\n";
' "$tmp/speech.wav" "$out"
