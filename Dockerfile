FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive \
    CCACHE_DIR=/ccache \
    CCACHE_MAXSIZE=2G

# 1) 打开 deb-src（apt-get source / build-dep 需要）
RUN sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources \
 && apt-get update

# 2) kwin 的构建依赖 + 工具链
RUN apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build pkg-config ccache git ca-certificates curl \
      dpkg-dev devscripts equivs \
 && apt-get build-dep -y kwin \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work
