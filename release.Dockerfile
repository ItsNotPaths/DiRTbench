# Build the complete release against the oldest supported userspace.  Building
# only SDL here would not lower the executable's glibc symbol floor.
FROM almalinux:8

RUN dnf -y install --setopt=install_weak_deps=False \
        gcc gcc-c++ clang make cmake git curl tar xz unzip pkgconf-pkg-config \
        libX11-devel libXext-devel libXrandr-devel libXcursor-devel libXi-devel \
        libXfixes-devel libXrender-devel libXScrnSaver-devel \
        wayland-devel wayland-protocols-devel libxkbcommon-devel \
        mesa-libGL-devel mesa-libEGL-devel vulkan-headers vulkan-loader-devel \
        alsa-lib-devel pulseaudio-libs-devel pipewire-devel \
        cairo-devel pango-devel python3.12 python3.12-pip \
    && dnf clean all

RUN python3.12 -m pip install --no-cache-dir meson ninja

ARG LIBDECOR_VERSION=0.2.2
RUN curl -fsSL "https://gitlab.freedesktop.org/libdecor/libdecor/-/archive/${LIBDECOR_VERSION}/libdecor-${LIBDECOR_VERSION}.tar.gz" \
        | tar xz -C /tmp \
    && cd "/tmp/libdecor-${LIBDECOR_VERSION}" \
    && meson setup build --prefix=/usr -Ddemo=false -Ddbus=disabled -Dgtk=disabled \
    && ninja -C build install \
    && rm -rf "/tmp/libdecor-${LIBDECOR_VERSION}"

ARG ODIN_VERSION=dev-2026-08
RUN mkdir -p /opt/odin \
    && curl -fsSL "https://github.com/odin-lang/Odin/releases/download/${ODIN_VERSION}/odin-linux-amd64-${ODIN_VERSION}.tar.gz" \
        | tar xz --strip-components=1 -C /opt/odin

ENV PATH="/opt/odin:${PATH}"
WORKDIR /work
