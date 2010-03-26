#! /bin/sh
# $1: input data [ height x y ... ]
# $2: output GIF file
dir="${0%/*}"
if test "$1" == "--vector"; then
    style=vector
else
    style=lines
fi
exec gnuplot -e "input='$1'; output='$2'" "$dir/gif240.gp" "$dir/$style.gp"
