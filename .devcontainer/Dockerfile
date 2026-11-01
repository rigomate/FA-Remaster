FROM mcr.microsoft.com/devcontainers/cpp:1-ubuntu-24.04

ARG DEBIAN_FRONTEND=noninteractive
# SDL 3 is not in Ubuntu 24.04's repos; ui/build_ui.py links against the system SDL 3,
# so it is built from source. Change the tag if you want a different 3.2.x release.
ARG SDL3_TAG=release-3.2.10

RUN apt-get update && apt-get install -y --no-install-recommends \
        ninja-build \
        python3 python3-pip python3-venv \
        git curl unzip \
        # Vulkan (renderer backend) + shader tooling
        libvulkan-dev vulkan-tools glslang-tools spirv-tools \
        # SDL 3 build dependencies (window, input, audio on Linux)
        libx11-dev libxext-dev libxcursor-dev libxi-dev libxrandr-dev libxss-dev \
        libxfixes-dev libxkbcommon-dev libwayland-dev wayland-protocols \
        libdrm-dev libgbm-dev libasound2-dev libpulse-dev libudev-dev \
        libdbus-1-dev libgl-dev libegl-dev \
    && rm -rf /var/lib/apt/lists/*

# Build and install SDL 3
RUN git clone --depth 1 --branch ${SDL3_TAG} https://github.com/libsdl-org/SDL.git /tmp/SDL \
    && cmake -S /tmp/SDL -B /tmp/SDL/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
    && cmake --build /tmp/SDL/build \
    && cmake --install /tmp/SDL/build \
    && ldconfig \
    && rm -rf /tmp/SDL

# Zig is used by tools/build_zig.py (the project's `py -m pip install ziglang` step)
RUN pip install --no-cache-dir --break-system-packages ziglang \
    # the README's commands use the Windows launcher `py`; provide it on Linux
    && ln -sf /usr/bin/python3 /usr/local/bin/py