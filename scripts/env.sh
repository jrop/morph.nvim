#!/usr/bin/env bash

export PREFIX="$(pwd)/.prefix"
export VIMRUNTIME="$(nvim -u NORC --headless +'echo $VIMRUNTIME' +'quitall' 2>&1)"

eval $(luarocks path)
