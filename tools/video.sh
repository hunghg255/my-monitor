#!/bin/sh
# The 30-second video of myzig, with sound: the frames rendered offscreen
# by mymonitor-video (src/video.zig), a soundtrack (any 30-second MP3), and
# sounds made here with ffmpeg at the script's cues: a soft tick for each
# click, a breath of air at each cut.
#
#     tools/video.sh [music.mp3] [out.mp4]
set -eu
cd "$(dirname "$0")/.."
music="${1:-zig-out/video/music.mp3}"
out="${2:-zig-out/video/myzig.mp4}"
mkdir -p zig-out/video
zig build video -Doptimize=ReleaseFast ${MYZIG_FORK:+--fork=$MYZIG_FORK}
bin=zig-out/bin/mymonitor-video
silent=zig-out/video/silent.mp4
"$bin" | ffmpeg -loglevel error -y -f rawvideo -pix_fmt bgra -s 1920x1080 -r 30 -i - \
    -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p "$silent"

tick="0.35*sin(2*PI*2400*t)*exp(-90*t)+0.25*sin(2*PI*1200*t)*exp(-60*t)"
graph="[1:a]apad=whole_dur=30,atrim=0:30,afade=t=out:st=29.2:d=0.8,volume=0.85[m]"
mix="[m]"
n=1
ms() { awk -v s="$1" -v d="$2" 'BEGIN { v = (s + d) * 1000; if (v < 0) v = 0; printf "%d", v }'; }
while read -r kind at; do
    n=$((n + 1))
    case "$kind" in
    click) src="aevalsrc=exprs='$tick':d=0.09:s=44100"; at=$(ms "$at" 0) ;;
    # The air peaks on the cut.
    cut) src="anoisesrc=d=0.7:c=pink:a=0.2:s=44100,highpass=f=500,lowpass=f=5000,afade=t=in:d=0.4,afade=t=out:st=0.4:d=0.3"; at=$(ms "$at" -0.4) ;;
    *) continue ;;
    esac
    graph="$graph;$src,aformat=channel_layouts=stereo,adelay=$at|$at[s$n]"
    mix="$mix[s$n]"
done <<EOF
$("$bin" --cues)
EOF
graph="$graph;${mix}amix=inputs=$n:normalize=0,alimiter=limit=0.95[a]"
ffmpeg -loglevel error -y -i "$silent" -i "$music" -filter_complex "$graph" \
    -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k -shortest -movflags +faststart "$out"
rm -f "$silent"
echo "$out"
