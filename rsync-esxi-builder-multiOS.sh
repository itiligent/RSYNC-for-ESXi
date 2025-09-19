#!/usr/bin/env bash
# Build static rsync for x86-64 VMware ESXi on Debian/Ubuntu or Fedora/RHEL.
# David Harrop.
# Run as a regular user. Only package installation requests sudo.
# Output: $HOME/build-static/rsync/bin/rsync
#
# Libraries are rebuilt each run; source downloads are reused.
# If static glibc is unavailable, build a private copy without changing system libc.
# MD5 works with OpenSSL 4, or with ENABLE_OPENSSL=false using rsync's own code.
# SSH transport is independent of OpenSSL.
# IDN hostname conversion is disabled to avoid additional libraries.

clear

set -Eeuo pipefail
trap 'printf "ERROR: Build failed at line %s. See the preceding output.\n" "$LINENO" >&2' ERR

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

# User settings. Set INSTALL_DEPS=false if build packages are already installed.
WORKDIR="${WORKDIR:-$HOME/build-static}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN)}"
INSTALL_DEPS="${INSTALL_DEPS:-true}"
ENABLE_OPENSSL="${ENABLE_OPENSSL:-false}"

# Source versions.
RSYNC_VER=3.5.1
ZLIB_VER=1.3.2
LZ4_VER=1.10.0
ZSTD_VER=1.5.7
POPT_VER=1.19
XXHASH_VER=0.8.4
OPENSSL_VER=4.0.3
# Keep glibc baseline 2.39 for compatibility with build hosts.
# RHEL 10 = 2.39. | Fedora 42 = 2.41 | Fedora 43 = 2.44
GLIBC_VER=2.39

[[ "$(id -u)" -ne 0 ]] || die "Run as a regular user, without sudo."
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] ||
    die "Use an x86-64 Linux build host."
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer."
[[ "$INSTALL_DEPS" == true || "$INSTALL_DEPS" == false ]] ||
    die "INSTALL_DEPS must be true or false."
[[ "$ENABLE_OPENSSL" == true || "$ENABLE_OPENSSL" == false ]] ||
    die "ENABLE_OPENSSL must be true or false."
[[ "$WORKDIR" == /* && ! "$WORKDIR" =~ [[:space:]] ]] ||
    die "Use an absolute WORKDIR without whitespace."
mkdir -p -- "$WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
[[ "$WORKDIR" != / && ! "$WORKDIR" =~ [[:space:]] ]] || die "Invalid resolved WORKDIR."

# Use consistent compiler settings for all libraries and rsync.
export CC=gcc CXX=g++ CFLAGS=-O2 CXXFLAGS=-O2
export CPPFLAGS="" LDFLAGS="" LIBS=""

static_link_works() {
    printf 'int main(void) { return 0; }\n' |
        "$CC" -static -x c - -o "$WORKDIR/static-test" >"$WORKDIR/static-link.log" 2>&1
}

if [[ "$INSTALL_DEPS" == true ]]; then
    log "Installing build packages"
    if command -v apt-get >/dev/null; then
        PM=apt-get
        sudo apt-get update
        sudo apt-get install -y --no-install-recommends build-essential libc6-dev \
            curl ca-certificates perl tar gzip file binutils gawk
    elif command -v dnf >/dev/null || command -v yum >/dev/null; then
        if command -v dnf >/dev/null; then PM=dnf; else PM=yum; fi
        sudo "$PM" install -y gcc gcc-c++ make glibc-devel \
            curl ca-certificates perl-core tar gzip file binutils gawk
        if ! static_link_works; then
            sudo "$PM" install -y glibc-static || log "glibc-static unavailable; trying a source build"
        fi
    else
        die "Install build packages manually, then set INSTALL_DEPS=false."
    fi
fi

DEPS="$WORKDIR/deps"
SOURCES="$WORKDIR/src"
DOWNLOADS="$WORKDIR/downloads"
RSYNC="$WORKDIR/rsync"
rm -rf -- "$DEPS"
mkdir -p -- "$DEPS" "$SOURCES" "$DOWNLOADS"

# Download if needed, then extract a fresh source tree into SOURCE_DIR.
prepare_source() {
    local name="$1" url="$2"
    local archive="$DOWNLOADS/$name.${3:-tar.gz}"
    if [[ ! -f "$archive" ]]; then
        log "Downloading $name"
        curl --fail --location --retry 3 --connect-timeout 20 --output "$archive.part" "$url"
        mv -- "$archive.part" "$archive"
    fi
    SOURCE_DIR="$SOURCES/$name"
    rm -rf -- "$SOURCE_DIR"
    mkdir -p -- "$SOURCE_DIR"
    tar --no-same-owner --strip-components=1 -xf "$archive" -C "$SOURCE_DIR"
}

if ! static_link_works; then
    log "Building private glibc $GLIBC_VER from source"
    if [[ "$INSTALL_DEPS" == true ]]; then
        if [[ "$PM" == apt-get ]]; then
            sudo apt-get install -y --no-install-recommends bison gawk python3 xz-utils linux-libc-dev
        else
            sudo "$PM" install -y bison gawk python3 xz kernel-headers
        fi
    fi
    for tool in bison gawk python3 m4 xz; do
        command -v "$tool" >/dev/null || die "Source glibc needs $tool. Install it and rerun."
    done
    GLIBC="$WORKDIR/glibc"
    GLIBC_BUILD="$WORKDIR/glibc-build"
    prepare_source "glibc-$GLIBC_VER" \
        "https://ftp.gnu.org/gnu/glibc/glibc-$GLIBC_VER.tar.xz" tar.xz
    rm -rf -- "$GLIBC" "$GLIBC_BUILD"
    mkdir -p -- "$GLIBC_BUILD"
    (
        cd "$GLIBC_BUILD"
        # glibc requires a separate build directory and must not fortify itself.
        export CFLAGS="-O2 -U_FORTIFY_SOURCE" CXXFLAGS="-O2 -U_FORTIFY_SOURCE"
        "$SOURCE_DIR/configure" --prefix="$GLIBC" --libdir="$GLIBC/lib" \
            --sysconfdir="$GLIBC/etc" --localstatedir="$GLIBC/var" \
            --disable-multilib --disable-profile --disable-nscd --disable-werror --enable-kernel=3.2
        make -j"$JOBS" CFLAGS="$CFLAGS"
        make install CFLAGS="$CFLAGS"
    )

    # All subsequent builds must use this glibc's headers, libraries AND startup objects.
    # Wrappers also make configure's helper programs static for older build hosts.
    mkdir -p -- "$WORKDIR/toolchain"
    for compiler in gcc g++; do
        printf '#!/usr/bin/env bash\nexec %q -static -no-pie -isystem %q -B%q -L%q "$@"\n' \
            "$(command -v "$compiler")" "$GLIBC/include" "$GLIBC/lib/" "$GLIBC/lib" \
            >"$WORKDIR/toolchain/$compiler"
        chmod 755 "$WORKDIR/toolchain/$compiler"
    done
    export CC="$WORKDIR/toolchain/gcc" CXX="$WORKDIR/toolchain/g++"
    [[ "$("$CC" -print-file-name=crt1.o)" == "$GLIBC/lib/crt1.o" &&
       "$("$CC" -print-file-name=libc.a)" == "$GLIBC/lib/libc.a" ]] ||
        die "Private glibc was not selected."
    static_link_works || die "Private glibc could not link. See $WORKDIR/static-link.log."
else
    log "Using system static glibc"
fi
rm -f -- "$WORKDIR/static-test" "$WORKDIR/static-link.log"

log "Building zlib $ZLIB_VER"
prepare_source "zlib-$ZLIB_VER" "https://zlib.net/fossils/zlib-$ZLIB_VER.tar.gz"
(
    cd "$SOURCE_DIR"
    ./configure --static --prefix="$DEPS" --libdir="$DEPS/lib"
    make -j"$JOBS"
    make install
)

log "Building LZ4 $LZ4_VER"
prepare_source "lz4-$LZ4_VER" \
    "https://github.com/lz4/lz4/archive/refs/tags/v$LZ4_VER.tar.gz"
(
    cd "$SOURCE_DIR"
    make -C lib -j"$JOBS" BUILD_SHARED=no liblz4.a
    make -C lib BUILD_SHARED=no prefix="$DEPS" libdir="$DEPS/lib" install
)

log "Building Zstandard $ZSTD_VER"
prepare_source "zstd-$ZSTD_VER" \
    "https://github.com/facebook/zstd/releases/download/v$ZSTD_VER/zstd-$ZSTD_VER.tar.gz"
(
    cd "$SOURCE_DIR"
    make -C lib -j"$JOBS" libzstd.a
    make -C lib PREFIX="$DEPS" LIBDIR="$DEPS/lib" install-static install-includes install-pc
)

log "Building popt $POPT_VER"
prepare_source "popt-$POPT_VER" \
    "https://ftp.osuosl.org/pub/rpm/popt/releases/popt-1.x/popt-$POPT_VER.tar.gz"
(
    cd "$SOURCE_DIR"
    ./configure --prefix="$DEPS" --libdir="$DEPS/lib" --disable-shared --enable-static --disable-nls
    make -j"$JOBS"
    make install
)

log "Building xxHash $XXHASH_VER"
prepare_source "xxHash-$XXHASH_VER" \
    "https://github.com/Cyan4973/xxHash/archive/refs/tags/v$XXHASH_VER.tar.gz"
(
    cd "$SOURCE_DIR"
    make -j"$JOBS" libxxhash.a
    make PREFIX="$DEPS" LIBDIR="$DEPS/lib" install_libxxhash.a install_libxxhash.includes install_libxxhash.pc
)

OPENSSL_OPTION=--disable-openssl
if [[ "$ENABLE_OPENSSL" == true ]]; then
    log "Building OpenSSL $OPENSSL_VER"
    prepare_source "openssl-$OPENSSL_VER" \
        "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz"
    (
        cd "$SOURCE_DIR"
        ./Configure linux-x86_64 no-shared no-module no-dso no-async no-tests --prefix="$DEPS" --libdir=lib
        make -j"$JOBS" build_libs
        make install_dev
    )
    OPENSSL_OPTION=--enable-openssl
fi

log "Building static rsync $RSYNC_VER"
prepare_source "rsync-$RSYNC_VER" \
    "https://download.samba.org/pub/rsync/src/rsync-$RSYNC_VER.tar.gz"
(
    cd "$SOURCE_DIR"
    CPPFLAGS="-I$DEPS/include" LDFLAGS="-static -L$DEPS/lib" LIBS="-ldl -lm -pthread" \
        ./configure --prefix="$RSYNC" --disable-md2man --disable-idn \
        --with-included-zlib=no --with-included-popt=no "$OPENSSL_OPTION"
    # Fail if configure silently dropped one of the requested libraries.
    for feature in EXTERNAL_ZLIB HAVE_LIBPOPT SUPPORT_XXHASH SUPPORT_LZ4 SUPPORT_ZSTD; do
        grep -q "^#define $feature 1$" config.h || die "Missing library support: $feature"
    done
    if [[ "$ENABLE_OPENSSL" == true ]]; then
        grep -q '^#define USE_OPENSSL 1$' config.h || die "OpenSSL support was not enabled."
    fi
    make -j"$JOBS"
    make install
)

log "Checking the new rsync binary"
BINARY="$RSYNC/bin/rsync"
strip --strip-all "$BINARY"
ELF_INFO="$(readelf -lW -dW "$BINARY")"
[[ "$ELF_INFO" != *INTERP* && "$ELF_INFO" != *NEEDED* ]] ||
    die "The binary has a shared-library dependency."
VERSION_INFO="$("$BINARY" --version)"
printf '%s\n' "$VERSION_INFO"
grep -qw md5 <<<"$VERSION_INFO" || die "MD5 support is missing."
printf '\nBinary details:\n'
file "$BINARY"
printf '\nSHA-256 checksum:\n'
sha256sum "$BINARY"

# Use colour in terminals; keep redirected logs plain. NO_COLOR disables colour.
GREEN='' CYAN='' RESET=''
if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]]; then
    GREEN=$'\033[1;32m'
    CYAN=$'\033[1;36m'
    RESET=$'\033[0m'
fi

printf '\n%sBuild completed successfully.%s\n' "$GREEN" "$RESET"
printf '\nYour new rsync binary is here:\n  %s%s%s\n' "$CYAN" "$BINARY" "$RESET"
printf '\nCopy this file to your ESXi host and make it executable before running it.\n'
