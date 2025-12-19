#!/bin/bash

img="$1"

trailing_zeros_start_at="$(hexdump "${img}" | tail -n 3 | grep '^\*$' -B 1 | head -n 1 | cut -f1 -d' ')"

if [ -z "${trailing_zeros_start_at}" ]
then
	# No trailing NULLs, so we're done
	exit 0
fi

truncate --size $((0x0${trailing_zeros_start_at})) ${img}
