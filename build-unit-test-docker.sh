#!/bin/bash -xe
#
# Build the required docker image to run package unit tests
#
# Script Variables:
#   DOCKER_IMG_NAME:  <optional, the name of the docker image to generate>
#                     default is openbmc/ubuntu-unit-test
#   DISTRO:           <optional, the distro to build a docker image against>
#                     default is ubuntu:bionic
#   BRANCH:           <optional, branch to build from each of the openbmc/
#                     respositories>
#                     default is master, which will be used if input branch not
#                     provided or not found

set -uo pipefail

DOCKER_IMG_NAME=${DOCKER_IMG_NAME:-"openbmc/ubuntu-unit-test"}
DISTRO=${DISTRO:-"ubuntu:bionic"}
BRANCH=${BRANCH:-"master"}

# Determine the architecture
ARCH=$(uname -m)
case ${ARCH} in
    "ppc64le")
        DOCKER_BASE="ppc64le/"
        ;;
    "x86_64")
        DOCKER_BASE=""
        ;;
    *)
        echo "Unsupported system architecture(${ARCH}) found for docker image"
        exit 1
esac

# Setup temporary files
DEPCACHE_FILE=""
cleanup() {
  local status="$?"
  if [[ -n "$DEPCACHE_FILE" ]]; then
    rm -f "$DEPCACHE_FILE"
  fi
  trap - EXIT ERR
  exit "$status"
}
trap cleanup EXIT ERR INT TERM QUIT
DEPCACHE_FILE="$(mktemp)"

HEAD_PKGS=(
  phosphor-objmgr
  sdbusplus
  sdeventplus
  gpioplus
  phosphor-logging
  phosphor-dbus-interfaces
  openpower-dbus-interfaces
)

# Generate a list of depcache entries
# We want to do this in parallel since the package list is growing
# and the network lookup is low overhead but decently high latency.
# This doesn't worry about producing a stable DEPCACHE_FILE, that is
# done by readers who need a stable ordering.
generate_depcache_entry() {
  local package="$1"

  local tip
  # Need to continue if branch not found, hence || true at end
  tip=$(git ls-remote --heads "https://github.com/openbmc/${package}" |
        grep "refs/heads/$BRANCH" | awk '{ print $1 }' || true)

  # If specific branch is not found then try master
  if [ ! -n "$tip" ]; then
    tip=$(git ls-remote --heads "https://github.com/openbmc/${package}" |
         grep "refs/heads/master" | awk '{ print $1 }')
  fi

  # Lock the file to avoid interlaced writes
  exec 3>> "$DEPCACHE_FILE"
  flock -x 3
  echo "$package:$tip" >&3
  exec 3>&-
}
for package in "${HEAD_PKGS[@]}"; do
  generate_depcache_entry "$package" &
done
wait

# A list of package versions we are building
# Start off by listing the stating versions of third-party sources
declare -A PKG_REV=(
  [boost]=1.68.0
  [cereal]=v1.2.2
  [CLI11]=v1.7.1
  # Snapshot from 2018-12-17
  [googletest]=9ab640ce5e5120021c5972d7e60f258bfca64d71
  [json]=v3.3.0
  # Snapshot from 2019-01-11
  [lcov]=04335632c371b5066e722298c9f8c6f11b210201
  # libvncserver commit dd873fce451e4b7d7cc69056a62e107aae7c8e7a is required for obmc-ikvm
  # Snapshot from 2018-10-08
  [libvncserver]=7b1ef0ffc4815cab9a96c7278394152bdc89dc4d
  # version from meta-openembedded/meta-oe/recipes-support/libtinyxml2/libtinyxml2_5.0.1.bb
  [tinyxml2]=37bc3aca429f0164adf68c23444540b4a24b5778
  [cppcheck]=df32b0fb05f0c951ab0efa691292c7428f3f50a9
)

# Turn the depcache into a dictionary so we can reference the HEAD of each repo
for line in $(cat "$DEPCACHE_FILE"); do
  linearr=($(echo "$line" | tr ':' ' '))
  PKG_REV["${linearr[0]}"]="${linearr[1]}"
done

# Define common flags used for builds
PREFIX="/usr/local"
CONFIGURE_FLAGS=(
  "--prefix=${PREFIX}"
)
CMAKE_FLAGS=(
  "-DCMAKE_BUILD_TYPE=RelWithDebInfo"
  "-DBUILD_SHARED_LIBS=ON"
  "-DCMAKE_INSTALL_PREFIX:PATH=${PREFIX}"
)

# Build the commands needed to compose our final image
COPY_CMDS=""
# We must sort the packages, otherwise we might produce an unstable
# docker file and rebuild the image unnecessarily
for pkg in $(echo "${!PKG_REV[@]}" | tr ' ' '\n' | LC_COLLATE=C sort -s); do
  COPY_CMDS+="COPY --from=openbmc-${pkg} ${PREFIX} ${PREFIX}"$'\n'
  # Workaround for upstream docker bug and multiple COPY cmds
  # https://github.com/moby/moby/issues/37965
  COPY_CMDS+="RUN true"$'\n'
done

################################# docker img # #################################
# Create docker image that can run package unit tests
if [[ "${DISTRO}" == "ubuntu"* ]]; then
Dockerfile=$(cat << EOF
FROM ${DOCKER_BASE}${DISTRO} as openbmc-base

ENV DEBIAN_FRONTEND noninteractive

# We need the keys to be imported for dbgsym repos
# New releases have a package, older ones fall back to manual fetching
# https://wiki.ubuntu.com/Debug%20Symbol%20Packages
RUN apt-get update && ( apt-get install ubuntu-dbgsym-keyring || ( apt-get install -yy dirmngr && \
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys F2EDC64DC5AEE1F6B9C621F0C8CAB6595FDFF622 ) )

# Parse the current repo list into a debug repo list
RUN sed -n '/^deb /s,^deb [^ ]* ,deb http://ddebs.ubuntu.com ,p' /etc/apt/sources.list >/etc/apt/sources.list.d/debug.list

# Remove non-existent debug repos
RUN sed -i '/-\(backports\|security\) /d' /etc/apt/sources.list.d/debug.list

RUN cat /etc/apt/sources.list.d/debug.list

RUN apt-get update && apt-get install -yy \
    gcc-8 \
    g++-8 \
    libc6-dbg \
    libc6-dev \
    libtool \
    cmake \
    python \
    python-dev \
    python-git \
    python-yaml \
    python-mako \
    python-pip \
    python-setuptools \
    python-socks \
    python3 \
    python3-dev\
    python3-yaml \
    python3-mako \
    python3-pip \
    python3-setuptools \
    pkg-config \
    autoconf \
    autoconf-archive \
    libsystemd-dev \
    libsystemd0-dbgsym \
    libssl-dev \
    libevdev-dev \
    libevdev2-dbgsym \
    libjpeg-dev \
    libpng-dev \
    ninja-build \
    sudo \
    curl \
    git \
    dbus \
    iputils-ping \
    clang-6.0 \
    clang-format-6.0 \
    clang-tidy-6.0 \
    clang-tools-6.0 \
    iproute2 \
    libnl-3-dev \
    libnl-genl-3-dev \
    libconfig++-dev \
    libsnmp-dev \
    valgrind \
    valgrind-dbg \
    libpam0g-dev \
    xxd \
    libi2c-dev \
    wget \
    libldap2-dev \
    libprotobuf-dev \
    protobuf-compiler

# Make gcc8 and g++8 the default
RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-8 800 \
  --slave /usr/bin/g++ g++ /usr/bin/g++-8 \
  --slave /usr/bin/gcov gcov /usr/bin/gcov-8 \
  --slave /usr/bin/gcov-dump gcov-dump /usr/bin/gcov-dump-8 \
  --slave /usr/bin/gcov-tool gcov-tool /usr/bin/gcov-tool-8

RUN pip install inflection
RUN pip install pycodestyle
RUN pip3 install meson==0.49.0

FROM openbmc-base as openbmc-lcov
RUN curl -L https://github.com/linux-test-project/lcov/archive/${PKG_REV['lcov']}.tar.gz | tar -xz && \
cd lcov-* && \
make -j$(nproc) && \
make install

FROM openbmc-base as openbmc-googletest
RUN curl -L https://github.com/google/googletest/archive/${PKG_REV['googletest']}.tar.gz | tar -xz && \
cd googletest-* && \
mkdir build && \
cd build && \
cmake ${CMAKE_FLAGS[@]} -DTHREADS_PREFER_PTHREAD_FLAG=ON .. && \
make -j$(nproc) && \
make install

FROM openbmc-base as openbmc-cereal
RUN curl -L https://github.com/USCiLab/cereal/archive/${PKG_REV['cereal']}.tar.gz | tar -xz && \
cp -a cereal-*/include/cereal/ ${PREFIX}/include/

FROM openbmc-base as openbmc-CLI11
RUN curl -L https://github.com/CLIUtils/CLI11/archive/${PKG_REV['CLI11']}.tar.gz | tar -xz && \
cd CLI11-* && \
mkdir build && \
cd build && \
cmake ${CMAKE_FLAGS[@]} -DCLI11_TESTING=OFF -DCLI11_EXAMPLES=OFF .. && \
make -j$(nproc) && \
make install

FROM openbmc-base as openbmc-json
RUN mkdir ${PREFIX}/include/nlohmann/ && \
curl -L -o ${PREFIX}/include/nlohmann/json.hpp https://github.com/nlohmann/json/releases/download/${PKG_REV['json']}/json.hpp

FROM openbmc-base as openbmc-boost
RUN curl -L https://dl.bintray.com/boostorg/release/${PKG_REV['boost']}/source/boost_$(echo "${PKG_REV['boost']}" | tr '.' '_').tar.bz2 | tar -xj && \
cd boost_*/ && \
./bootstrap.sh --prefix=${PREFIX} --with-libraries=context,coroutine && \
./b2 && ./b2 install --prefix=${PREFIX}

FROM openbmc-base as openbmc-cppcheck
RUN curl -L https://github.com/danmar/cppcheck/archive/${PKG_REV['cppcheck']}.tar.gz | tar -xz && \
cd cppcheck-* && \
mkdir "${PREFIX}/cppcheck-cfg" && cp cfg/* "${PREFIX}/cppcheck-cfg/" && \
make -j$(nproc) CFGDIR="${PREFIX}/cppcheck-cfg" CXXFLAGS="-O2 -DNDEBUG -Wall -Wno-sign-compare -Wno-unused-function" && \
make PREFIX=${PREFIX} install

FROM openbmc-base as openbmc-tinyxml2
RUN curl -L https://github.com/leethomason/tinyxml2/archive/${PKG_REV['tinyxml2']}.tar.gz | tar -xz && \
cd tinyxml2-* && \
mkdir build && \
cd build && \
cmake ${CMAKE_FLAGS[@]} .. && \
make -j$(nproc) && \
make install

FROM openbmc-base as openbmc-libvncserver
RUN curl -L https://github.com/LibVNC/libvncserver/archive/${PKG_REV['libvncserver']}.tar.gz | tar -xz && \
cd libvncserver-* && \
mkdir build && \
cd build && \
cmake ${CMAKE_FLAGS[@]} .. && \
make -j$(nproc) && \
make install

FROM openbmc-base as openbmc-sdbusplus
RUN curl -L https://github.com/openbmc/sdbusplus/archive/${PKG_REV['sdbusplus']}.tar.gz | tar -xz && \
cd sdbusplus-* && \
./bootstrap.sh && \
./configure ${CONFIGURE_FLAGS[@]} --disable-tests --enable-transaction && \
make -j$(nproc) && \
make install

FROM openbmc-base as openbmc-sdeventplus
RUN curl -L https://github.com/openbmc/sdeventplus/archive/${PKG_REV['sdeventplus']}.tar.gz | tar -xz && \
cd sdeventplus-* && \
./bootstrap.sh && \
./configure ${CONFIGURE_FLAGS[@]} --disable-tests --disable-examples && \
make -j$(nproc) && \
make install

FROM openbmc-base as openbmc-gpioplus
RUN curl -L https://github.com/openbmc/gpioplus/archive/${PKG_REV['gpioplus']}.tar.gz | tar -xz && \
cd gpioplus-* && \
./bootstrap.sh && \
./configure ${CONFIGURE_FLAGS[@]} --disable-tests --disable-examples && \
make -j$(nproc) && \
make install

FROM openbmc-base as openbmc-phosphor-dbus-interfaces
COPY --from=openbmc-sdbusplus ${PREFIX} ${PREFIX}
RUN curl -L https://github.com/openbmc/phosphor-dbus-interfaces/archive/${PKG_REV['phosphor-dbus-interfaces']}.tar.gz | tar -xz && \
cd phosphor-dbus-interfaces-* && \
./bootstrap.sh && \
./configure ${CONFIGURE_FLAGS[@]} && \
make -j$(nproc) && \
make install

FROM openbmc-base as openbmc-openpower-dbus-interfaces
COPY --from=openbmc-sdbusplus ${PREFIX} ${PREFIX}
RUN curl -L https://github.com/openbmc/openpower-dbus-interfaces/archive/${PKG_REV['openpower-dbus-interfaces']}.tar.gz | tar -xz && \
cd openpower-dbus-interfaces-* && \
./bootstrap.sh && \
./configure ${CONFIGURE_FLAGS[@]} && \
make -j$(nproc) && \
make install

FROM openbmc-base as openbmc-phosphor-logging
COPY --from=openbmc-cereal ${PREFIX} ${PREFIX}
COPY --from=openbmc-sdbusplus ${PREFIX} ${PREFIX}
COPY --from=openbmc-phosphor-dbus-interfaces ${PREFIX} ${PREFIX}
COPY --from=openbmc-openpower-dbus-interfaces ${PREFIX} ${PREFIX}
RUN curl -L https://github.com/openbmc/phosphor-logging/archive/${PKG_REV['phosphor-logging']}.tar.gz | tar -xz && \
cd phosphor-logging-* && \
./bootstrap.sh && \
./configure ${CONFIGURE_FLAGS[@]} --enable-metadata-processing YAML_DIR=${PREFIX}/share/phosphor-dbus-yaml/yaml && \
make -j$(nproc) && \
make install

FROM openbmc-base as openbmc-phosphor-objmgr
COPY --from=openbmc-boost ${PREFIX} ${PREFIX}
COPY --from=openbmc-sdbusplus ${PREFIX} ${PREFIX}
COPY --from=openbmc-tinyxml2 ${PREFIX} ${PREFIX}
COPY --from=openbmc-phosphor-logging ${PREFIX} ${PREFIX}
RUN curl -L https://github.com/openbmc/phosphor-objmgr/archive/${PKG_REV['phosphor-objmgr']}.tar.gz | tar -xz && \
cd phosphor-objmgr-* && \
./bootstrap.sh && \
./configure ${CONFIGURE_FLAGS[@]} --enable-unpatched-systemd && \
make -j$(nproc) && \
make install


# Build the final output image
FROM openbmc-base
${COPY_CMDS}

# Some of our infrastructure still relies on the presence of this file
# even though it is no longer needed to rebuild the docker environment
# NOTE: The file is sorted to ensure the ordering is stable.
RUN echo '$(LC_COLLATE=C sort -s "$DEPCACHE_FILE" | tr '\n' ',')' > /tmp/depcache

# Final configuration for the workspace
RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN mkdir -p $(dirname ${HOME})
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}
RUN sed -i '1iDefaults umask=000' /etc/sudoers
RUN echo "${USER} ALL=(ALL) NOPASSWD: ALL" >>/etc/sudoers

RUN /bin/bash
EOF
)
fi
################################# docker img # #################################

# Build above image
docker build --network=host -t ${DOCKER_IMG_NAME} - <<< "${Dockerfile}"
