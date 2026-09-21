# The release build image.
#
# AlmaLinux 8 is glibc 2.28. Linking on a newer host stamps newer symbol
# versions into the binary and glibc is never forward compatible, so a build on
# Arch (2.43) starts on Arch and nowhere else. Everything dirtbench links has to
# be compiled here, not just SDL: the final link is what sets the floor.
#
# glslc is not here. It needs glibc 2.38 and will not run on this image. SPIR-V
# is host-independent, so build-shaders.sh runs outside and build/shaders/ is
# mounted in.
FROM almalinux:8

# powertools carries wayland-protocols-devel and vulkan-loader-devel.
RUN dnf install -y --enablerepo=powertools \
        gcc gcc-c++ clang cmake make tar gzip curl which findutils \
        libstdc++-static \
        libX11-devel libXext-devel libXrandr-devel libXcursor-devel \
        libXi-devel libXfixes-devel libXScrnSaver-devel \
        wayland-devel wayland-protocols-devel libxkbcommon-devel \
        mesa-libEGL-devel mesa-libGL-devel vulkan-headers vulkan-loader-devel \
        alsa-lib-devel pulseaudio-libs-devel pipewire-devel dbus-devel \
        libdrm-devel \
    && dnf clean all

# The compiler ships statically linked, so it runs on this glibc untouched.
# Pinned: a release must be reproducible, and Odin is a nightly.
ARG ODIN_VERSION=dev-2026-08
RUN mkdir -p /opt/odin \
    && curl -fsSL "https://github.com/odin-lang/Odin/releases/download/${ODIN_VERSION}/odin-linux-amd64-${ODIN_VERSION}.tar.gz" \
       | tar xz --strip-components=1 -C /opt/odin \
    && /opt/odin/odin version
# The release tarball ships vendor:stb as source. src/gfx decodes Ogg Vorbis
# through stb_vorbis, and the binding panics at compile time without these.
RUN cd /opt/odin/vendor/stb/src && ./build_stb.sh
ENV PATH="/opt/odin:${PATH}"

# `foreign import` in src/ names ../../vendor/imgui/libimgui.a, so the archives
# have to sit at /src/vendor. release.sh mounts a container-only directory over
# it: a host-built archive reused here puts the glibc floor straight back up.
WORKDIR /src
ENTRYPOINT ["/bin/bash"]
