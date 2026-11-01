#!/bin/bash
cmake -B build -G Ninja && cmake --build build
py tools/build_zig.py --target x86_64-linux-gnu
py ui/build_ui.py
cp /usr/local/lib/libSDL3.so.0 .