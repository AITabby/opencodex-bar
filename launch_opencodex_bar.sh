#!/bin/bash
set -m
cd "/Users/aitabby/projects/opencodex-bar"
"/Users/aitabby/projects/opencodex-bar/.build/arm64-apple-macosx/release/OpenCodexBar" &
disown
exit
