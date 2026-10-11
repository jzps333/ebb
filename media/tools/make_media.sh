#!/usr/bin/env bash
# Builds the watch-ready scene media from media/raw (downloads, see docs/credits.md)
# into media/out. Re-run after changing any setting below.
#
# Video: seamless 5 s loop (the last second cross-fades into the first, so the
# loop point is invisible), centre-cropped to 240x240, 10 fps GIF with its own
# 48-colour palette, lightly denoised and undithered so busy footage stays
# near 1 MB (the watch holds ~9.9 MB). Audio: mono 22.05 kHz MP3 at 32 kbps, loudness-matched.
set -euo pipefail
cd "$(dirname "$0")/.."
RAW=raw
OUT=out
LOOP=5      # seconds in the final loop
FADE=1      # seconds of cross-fade at the loop point
FPS=10
SIZE=240

# video_loop <input> <start seconds> <output name> [smoothing filters] [colours]
# Busy footage (water, leaves) needs more smoothing to stay near 1 MB.
video_loop() {
  local in=$1 start=$2 name=$3 smooth=${4:-hqdn3d=3:3:8:8} colors=${5:-48}
  local len=$((LOOP + FADE))
  ffmpeg -v error -y -ss "$start" -t "$len" -i "$in" -filter_complex "
    [0:v]fps=$FPS,scale=-2:$SIZE:flags=lanczos,crop=$SIZE:$SIZE,setsar=1,$smooth,split[a][b];
    [a]trim=$FADE:$len,setpts=PTS-STARTPTS[main];
    [b]trim=0:$FADE,setpts=PTS-STARTPTS[head];
    [main][head]xfade=transition=fade:duration=$FADE:offset=$((LOOP - FADE)),split[v][p];
    [p]palettegen=max_colors=$colors:stats_mode=full[pal];
    [v][pal]paletteuse=dither=none:diff_mode=rectangle" \
    -loop 0 "$OUT/video/$name.gif"
  echo "video $name: $(du -h "$OUT/video/$name.gif" | cut -f1)"
}

# audio_loop <input> <start> <seconds> <output name> [fade seconds]
# A loop of <seconds> whose last <fade> seconds cross-fade into its start.
audio_loop() {
  local in=$1 start=$2 secs=$3 name=$4 fade=${5:-2}
  local len=$((secs + fade))
  ffmpeg -v error -y -ss "$start" -t "$len" -i "$in" -filter_complex "
    [0:a]aformat=channel_layouts=mono,aresample=22050,loudnorm=I=-23:TP=-2,asplit[a][b];
    [a]atrim=$fade:$len,asetpts=PTS-STARTPTS[main];
    [b]atrim=0:$fade,asetpts=PTS-STARTPTS[head];
    [main][head]acrossfade=d=$fade:c1=tri:c2=tri" \
    -c:a libmp3lame -b:a 32k "$OUT/audio/$name.mp3"
  echo "audio $name: $(du -h "$OUT/audio/$name.mp3" | cut -f1)"
}

mkdir -p "$OUT/video" "$OUT/audio"

# Videos from downloads (start times picked to avoid cuts and camera moves)
video_loop "$RAW/ocean_waves.ogv"       4  ocean  "hqdn3d=6:6:12:12,gblur=sigma=0.7" 32
video_loop "$RAW/forest_maple.mp4"      10 forest "hqdn3d=5:5:10:10,gblur=sigma=0.5" 40
video_loop "$RAW/animals_clownfish.mp4" 2  animals
video_loop "$RAW/space_earth.mp4"       2  space

# Generated video (no download, no licence). Its starfield is replaced by real
# footage above: drawn on the watch it showed a see-through artefact.
python3 tools/make_generated.py "$OUT/video" shapes

# Sounds
audio_loop "$RAW/rain/2.ogg"          0  30 rain
audio_loop "$RAW/ocean_vistula.mp3"   20 30 ocean
# Piano is music, not a loop: 45 s with a gentle fade in and out, played on repeat.
ffmpeg -v error -y -ss 15 -t 45 -i "$RAW/piano_vaporware.mp3" \
  -af "aformat=channel_layouts=mono,aresample=22050,loudnorm=I=-23:TP=-2,afade=t=in:d=3,afade=t=out:st=40:d=5" \
  -c:a libmp3lame -b:a 32k "$OUT/audio/soft_piano.mp3"
echo "audio soft_piano: $(du -h "$OUT/audio/soft_piano.mp3" | cut -f1)"
# Brown noise, synthesised: soft and warm (low-passed), no licence needed.
ffmpeg -v error -y -f lavfi -i "anoisesrc=color=brown:amplitude=0.6:duration=32:seed=7" \
  -filter_complex "[0:a]lowpass=f=900,aresample=22050,loudnorm=I=-26:TP=-3,asplit[a][b];
    [a]atrim=2:32,asetpts=PTS-STARTPTS[main];[b]atrim=0:2,asetpts=PTS-STARTPTS[head];
    [main][head]acrossfade=d=2" \
  -c:a libmp3lame -b:a 32k "$OUT/audio/brown_noise.mp3"
echo "audio brown_noise: $(du -h "$OUT/audio/brown_noise.mp3" | cut -f1)"

du -ch "$OUT"/video/* "$OUT"/audio/* | tail -1
