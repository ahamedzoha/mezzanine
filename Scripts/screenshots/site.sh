#!/bin/zsh
# The website's pictures, from the captures all.sh left in build.noindex/shots: whole windows with their
# rounded corners (WebP at two widths, JPEG for browsers without it) and a few close crops.
set -eu
root=${0:A:h:h:h}; shots=$root/build.noindex/shots; out=$root/site/img; tmp=$(mktemp -d)
mkdir -p $out
put() { # name source.png widths…
  local name=$1 src=$2; shift 2
  for w in $@; do cwebp -quiet -q 82 -alpha_q 90 -resize $w 0 $src -o $out/$name-$w.webp; done
  ffmpeg -v error -y -i $src -vf "scale=1280:-2" -frames:v 1 $tmp/$name-small.png
  ffmpeg -v error -y -f lavfi -i "color=0x0E0F11:s=$(sips -g pixelWidth -g pixelHeight $tmp/$name-small.png | awk '/pixel/{print $2}' | paste -sd x -)" -i $tmp/$name-small.png -filter_complex "overlay" -frames:v 1 -q:v 4 $out/$name.jpg
}
crop() { ffmpeg -v error -y -i $shots/$2.png -vf "crop=$3" -frames:v 1 $tmp/$1.png; }
for n in home player subtitle before mini unwatched; do put $n $shots/$n.png 1200 2400; done
crop quickopen quickopen "1244:944:534:70"; put quickopen $tmp/quickopen.png 620 1240
crop credits credits "2880:1120:0:190"; put credits $tmp/credits.png 1200 2400
crop queue queue "840:570:2000:705"; put queue $tmp/queue.png 420 840
crop sleep sleep "840:860:2000:420"; put sleep $tmp/sleep.png 420 840
cp -f $root/docs/screenshots/icon.png $out/icon.png
sips -s format png -z 64 64 $out/icon.png --out $out/icon-64.png > /dev/null
sips -s format png -z 180 180 $out/icon.png --out $out/icon-180.png > /dev/null
swift ${0:A:h}/og.swift $shots/home.png $out/og.jpg
rm -r $tmp
du -sh $out
