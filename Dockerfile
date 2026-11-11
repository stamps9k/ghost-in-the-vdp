# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Stage 1: build the ROM
#
# Alpine 3.24, vasm v2.0 + binutils built from source (m68k-elf target).
# Carried over unchanged from sega-md-homebrew apart from the ROM name.
# ---------------------------------------------------------------------------
FROM alpine:3.24 AS builder

ARG BINUTILS_VERSION=2.46.1
# SHA-256 of binutils-${BINUTILS_VERSION}.tar.xz, checked against sourceware's
# published sha512.sum.
ARG BINUTILS_SHA256=e127a709cba24c76de8936cb7083dd768f28cd37eb010492e2f19b71eb1294e4

RUN apk add --no-cache \
    build-base \
    curl \
    texinfo \
    zlib-dev \
    bison \
    flex

# --- Build binutils (m68k-elf target) ----------------------------------------
#
# We need:
#   m68k-elf-ld       — linker
#   m68k-elf-objcopy  — convert ELF to raw binary (.bin ROM)
#   m68k-elf-nm       — symbol listing (useful for debugging)
#   m68k-elf-objdump  — disassembler / inspection
#
# We explicitly disable gold, gprof, and other tools we don't need to keep
# build time and binary size down.
# -----------------------------------------------------------------------------
RUN curl -fsSL \
    "https://sourceware.org/pub/binutils/releases/binutils-${BINUTILS_VERSION}.tar.xz" \
    -o /tmp/binutils.tar.xz \
  && echo "${BINUTILS_SHA256}  /tmp/binutils.tar.xz" | sha256sum -c - \
  && tar -xJf /tmp/binutils.tar.xz -C /tmp \
  && rm /tmp/binutils.tar.xz

RUN cd /tmp/binutils-${BINUTILS_VERSION} \
  && ./configure \
       --target=m68k-elf \
       --prefix=/opt/m68k \
       --disable-nls \
       --disable-werror \
       --disable-gold \
       --disable-gprof \
       --disable-gprofng \
       --with-sysroot \
  && make -j$(nproc) \
  && make install \
  && rm -rf /tmp/binutils-${BINUTILS_VERSION}

# --- Build vasm (m68k CPU, Motorola syntax) -----------------------------------
#
# Downloaded from the personal mirror rather than upstream
# (sun.hasenbraten.de serves only an unversioned tarball over plain HTTP
# and is not reliably available). The checksum still pins the exact file.
# -----------------------------------------------------------------------------
ARG VASM_SHA256=c84b2de1cbb87831795fe64a85c5d9a7002a766e3a7c30b0a2d7d5e99d878f49

RUN curl -fsSL \
    "https://github.com/stamps9k/vendor-archive/releases/download/vasm-2.0/vasm-2.0.tar.gz" \
    -o /tmp/vasm.tar.gz \
  && echo "${VASM_SHA256}  /tmp/vasm.tar.gz" | sha256sum -c - \
  && tar -xzf /tmp/vasm.tar.gz -C /tmp \
  && rm /tmp/vasm.tar.gz

RUN cd /tmp/vasm \
  && make CPU=m68k SYNTAX=mot \
  && mkdir -p /opt/vasm/bin \
  && cp vasmm68k_mot /opt/vasm/bin/ \
  && rm -rf /tmp/vasm

ENV PATH="/opt/m68k/bin:/opt/vasm/bin:${PATH}"

# --- Build the ROM ------------------------------------------------------------
WORKDIR /rom
COPY rom/ .

# Produces pkg/ghost.bin via the project's makefile + rom.ld
RUN make

# ---------------------------------------------------------------------------
# Stage 2: build the Genesis Plus GX libretro core for the test harness
#
# Pinned by commit. The core carries its own non-commercial licence (see
# its LICENSE.txt), so it is built here for testing only and is never
# committed or shipped in the runtime image.
# ---------------------------------------------------------------------------
FROM alpine:3.24 AS core

ARG GPGX_COMMIT=b9c2316441978d4015ba30e9a95d9b0e6f8ee981

RUN apk add --no-cache build-base git

RUN git init -q /gpgx \
  && cd /gpgx \
  && git remote add origin https://github.com/libretro/Genesis-Plus-GX \
  && git fetch -q --depth 1 origin "${GPGX_COMMIT}" \
  && git checkout -q FETCH_HEAD \
  && make -f Makefile.libretro -j$(nproc) \
  && cp genesis_plus_gx_libretro.so /genesis_plus_gx_libretro.so \
  && rm -rf /gpgx

# ---------------------------------------------------------------------------
# Stage 3: headless test harness
#
# Runs every tests/*.test script against the ROM built in stage 1 and writes
# screenshots plus summary.md to /out. Mount a host directory there:
#   docker build --target harness -t ghost-harness .
#   docker run --rm -v "$PWD/out:/out" ghost-harness
# ---------------------------------------------------------------------------
FROM builder AS harness

COPY --from=core /genesis_plus_gx_libretro.so /opt/gpgx/genesis_plus_gx_libretro.so
COPY harness/ /harness/
RUN make -C /harness
COPY tests/ /tests/

ENTRYPOINT ["/harness/run_tests.sh", "/harness/mdharness", \
            "/opt/gpgx/genesis_plus_gx_libretro.so", "/rom/pkg/ghost.bin", \
            "/tests", "/out"]

# ---------------------------------------------------------------------------
# Stage 4: serve the ROM via EmulatorJS (default target)
# ---------------------------------------------------------------------------
FROM nginx:1.31-alpine3.24 AS runtime

COPY web/index.html /usr/share/nginx/html/index.html
COPY web/robots.txt /usr/share/nginx/html/robots.txt

COPY --from=builder /rom/pkg/ghost.bin /usr/share/nginx/html/rom.bin

EXPOSE 80
