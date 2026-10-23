# SWGEmu Core3 server, built from upstream (github.com/swgemu/Core3) at a pinned commit.
# Build on the workstation and push to GHCR, see the SWGEmu section of CLAUDE.md.
#
# The k3s agents are Proxmox VMs on the R720 (Xeon E5-2670, Sandy Bridge: AVX but no AVX2/BMI/FMA).
# Upstream defaults to -march=native, which on the workstation would emit instructions the agents
# can't run (SIGILL), so native is turned off and the target is pinned to sandybridge.

FROM debian:bookworm AS build

ARG CORE3_REF=403893d9b9f8e6fa712fbb3cb1fcd8f0fe45bb79
ARG CLANG_VERSION=19
ARG JOBS=16

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates git gnupg lsb-release software-properties-common wget; \
    wget -qO /tmp/llvm.sh https://apt.llvm.org/llvm.sh; \
    bash /tmp/llvm.sh ${CLANG_VERSION}; \
    apt-get install -y --no-install-recommends \
        binutils cmake default-jre-headless libboost-thread-dev libdb5.3-dev libjemalloc-dev \
        liblua5.3-dev libmariadb-dev libmariadb-dev-compat libssl-dev make ninja-build zlib1g-dev; \
    rm -rf /var/lib/apt/lists/*

ENV CC=clang-${CLANG_VERSION} CXX=clang++-${CLANG_VERSION}

# Not /src: src/CMakeLists.txt maps .idl to autogen paths by replacing every "src/" in the absolute path
RUN set -eux; \
    git init -q /core3; \
    cd /core3; \
    git remote add origin https://github.com/swgemu/Core3.git; \
    git fetch -q --depth 50 origin "${CORE3_REF}"; \
    git checkout -q FETCH_HEAD; \
    git submodule update --init --recursive --depth 1

WORKDIR /core3/MMOCoreORB/build/unix/ninja

# Extra compiler flags, empty for production. The local test server uses -DDEBUG_AI, the only build where
# Core3.AiAgent.AiAgentLoadTesting keeps AI running with no player near (see dev/docker-compose.yml).
ARG CORE3_CXX_EXTRA=

RUN set -eux; \
    cmake -G Ninja ../../.. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="-march=sandybridge -mtune=sandybridge" \
        -DCMAKE_CXX_FLAGS="-march=sandybridge -mtune=sandybridge ${CORE3_CXX_EXTRA}" \
        -DENABLE_NATIVE=OFF \
        -DCOMPILE_TESTS=OFF \
        -DENABLE_BUILD_CLIENT=OFF \
        -DENABLE_CCACHE=OFF \
        -DRUN_GIT=ON; \
    ninja -j"${JOBS}" core3; \
    cp src/core3 /core3/MMOCoreORB/bin/core3; \
    # Fail the build if anything newer than Sandy Bridge slipped in (AVX2, BMI1/2, FMA).
    # tzcnt is left out: compilers emit "rep bsf" on purpose and objdump prints it as tzcnt.
    if objdump -d /core3/MMOCoreORB/bin/core3 | grep -qE '\s(vpbroadcast[bwdq]|vperm[dq]|vpgather|vfmadd|vfmsub|shlx|shrx|sarx|rorx|andn|pdep|pext)\s'; then \
        echo "core3 contains instructions the k3s agents can't run" >&2; exit 1; \
    fi

FROM debian:bookworm-slim

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates libatomic1 libboost-atomic1.74.0 libboost-thread1.74.0 libdb5.3 libjemalloc2 liblua5.3-0 libmariadb3 libssl3 \
        mariadb-client procps tzdata zlib1g; \
    rm -rf /var/lib/apt/lists/*; \
    useradd --uid 44400 --user-group --home-dir /opt/swgemu --shell /bin/bash swgemu

COPY --from=build /core3/MMOCoreORB/bin /opt/swgemu/bin
COPY --from=build /core3/MMOCoreORB/sql /opt/swgemu/sql
COPY entrypoint.sh /usr/local/bin/entrypoint
COPY console add-account /usr/local/bin/
# Our scripts, over Core3's empty custom_scripts hooks (see custom_scripts/ and the SWGEmu section of CLAUDE.md)
COPY custom_scripts /opt/swgemu/bin/scripts/custom_scripts

# Runtime state lives on the /data volume; config-local.lua and the console FIFO are made at start in /run/core3
RUN set -eux; \
    chmod 755 /usr/local/bin/entrypoint /usr/local/bin/console /usr/local/bin/add-account; \
    # Owned by the server user so a development loop can kubectl cp scripts in and reloadscreenplays
    chown -R swgemu:swgemu /opt/swgemu/bin/scripts/custom_scripts; \
    ldd /opt/swgemu/bin/core3 | grep 'not found' && exit 1; \
    cd /opt/swgemu/bin; \
    for d in databases navmeshes log exports; do rm -rf "$d"; ln -s "/data/$d" "$d"; done; \
    ln -s /run/core3/config-local.lua conf/config-local.lua; \
    install -d -o swgemu -g swgemu /data /run/core3 /tre

USER swgemu
WORKDIR /opt/swgemu/bin
EXPOSE 44453/udp 44455/tcp 44462/udp 44463/udp
ENTRYPOINT ["/usr/local/bin/entrypoint"]
