# Set automatically by BuildKit when building for a specific platform
# (e.g. docker buildx build --platform linux/arm64). Selects the
# architecture specific handling of the final image stage below.
ARG TARGETARCH

FROM debian:trixie-slim AS build-env
ENV DEBIAN_FRONTEND=noninteractive
ARG TESTS
ARG SOURCE_COMMIT
ARG BUSYBOX_VERSION=1.36.1
ARG BUSYBOX_SHA256=b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314
ARG SUPERVISOR_VERSION=4.2.5
ARG GO_VERSION=1.24.1
ARG PYTHON_A2S_VERSION=1.4.1

RUN apt-get update
RUN apt-get -y install apt-utils
RUN apt-get -y install build-essential curl git python3 python3-pip python3-venv shellcheck

# Install Go 1.24 manually (build host architecture aware)
RUN set -eu; \
    case "$(uname -m)" in \
        x86_64) goarch=amd64 ;; \
        aarch64) goarch=arm64 ;; \
        *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -L -o /tmp/go${GO_VERSION}.tar.gz "https://go.dev/dl/go${GO_VERSION}.linux-${goarch}.tar.gz" \
    && tar -C /usr/local -xzf /tmp/go${GO_VERSION}.tar.gz \
    && rm /tmp/go${GO_VERSION}.tar.gz
ENV PATH=$PATH:/usr/local/go/bin
ENV GOPATH=/go
ENV PATH=$PATH:$GOPATH/bin

WORKDIR /build/busybox
COPY ./busybox.config /build/busybox/.config
RUN set -eu; \
    for base in \
        https://sources.buildroot.net/busybox \
        https://downloads.yoctoproject.org/mirror/sources \
        https://busybox.net/downloads; do \
        echo "Fetching busybox-${BUSYBOX_VERSION}.tar.bz2 from ${base}"; \
        curl -fsSL --retry 3 --retry-all-errors --connect-timeout 15 --max-time 300 \
            -o /tmp/busybox.tar.bz2 "${base}/busybox-${BUSYBOX_VERSION}.tar.bz2" && break || true; \
    done; \
    echo "${BUSYBOX_SHA256}  /tmp/busybox.tar.bz2" | sha256sum -c -; \
    tar xjf /tmp/busybox.tar.bz2 --strip-components=1 -C /build/busybox; \
    make -j"$(nproc)"; \
    cp busybox /usr/local/bin/

WORKDIR /build/env2cfg
COPY ./env2cfg/ /build/env2cfg/
RUN if [ "${TESTS:-true}" = true ]; then \
    python3 -m venv ../env2cfg.tests.venv \
    && ../env2cfg.tests.venv/bin/pip3 install tox~=4.28.4 \
    && ../env2cfg.tests.venv/bin/tox \
    ; \
    fi

WORKDIR /build/valheim-logfilter
COPY ./valheim-logfilter/ /build/valheim-logfilter/
RUN if [ "${TESTS:-true}" = true ]; then \
    go test ./... \
    ; \
    fi
RUN go build -ldflags="-s -w" \
    && mv valheim-logfilter /usr/local/bin/

WORKDIR /build
COPY bootstrap /usr/local/sbin/
COPY valheim-tests /usr/local/bin/
COPY valheim-status /usr/local/bin/
COPY valheim-is-idle /usr/local/bin/
COPY valheim-bootstrap /usr/local/bin/
COPY valheim-backup /usr/local/bin/
COPY valheim-updater /usr/local/bin/
COPY valheim-plus-updater /usr/local/bin/
COPY bepinex-updater /usr/local/bin/
COPY valheim-server /usr/local/bin/
COPY box64.sh /usr/local/bin/box64
COPY defaults /usr/local/etc/valheim/
COPY common /usr/local/etc/valheim/
COPY contrib/* /usr/local/share/valheim/contrib/
RUN chmod 755 /usr/local/sbin/bootstrap /usr/local/bin/valheim-*
RUN if [ "${TESTS:-true}" = true ]; then \
    shellcheck -a -x -s bash -e SC2034 \
    /usr/local/sbin/bootstrap \
    /usr/local/bin/box64 \
    /usr/local/bin/valheim-tests \
    /usr/local/bin/valheim-backup \
    /usr/local/bin/valheim-is-idle \
    /usr/local/bin/valheim-bootstrap \
    /usr/local/bin/valheim-server \
    /usr/local/bin/valheim-updater \
    /usr/local/bin/valheim-plus-updater \
    /usr/local/bin/bepinex-updater \
    /usr/local/share/valheim/contrib/*.sh \
    ; \
    fi
WORKDIR /
RUN rm -rf /usr/local/lib/
# Debian's pip is modded to install to /usr/local by default.
# Freezes an old version of Setuptools to prevent a flood of deprecation
# notices while supervisor still uses it. Setuptools dependency can be removed
# when supervisor>=4.3.0 is released
RUN pip3 install --break-system-packages \
    python-a2s==${PYTHON_A2S_VERSION} \
    supervisor==${SUPERVISOR_VERSION} \
    "Setuptools<67.5.0" \
    /build/env2cfg
COPY supervisord.conf /usr/local/etc/supervisord.conf
RUN mkdir -p /usr/local/etc/supervisor/conf.d/ \
    && chmod 640 /usr/local/etc/supervisord.conf
RUN echo "${SOURCE_COMMIT:-unknown}" > /usr/local/etc/git-commit.HEAD


FROM --platform=linux/386 debian:buster-slim AS i386-libs
ENV DEBIAN_FRONTEND=noninteractive
RUN sed -i -E 's/(deb|security).debian.org/archive.debian.org/g' /etc/apt/sources.list \
    && apt-get update \
    && apt-get -y --no-install-recommends install \
    libc6-dev \
    libstdc++6 \
    libsdl2-2.0-0 \
    libcurl4 \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*


# The 32-bit x86 libraries are only needed in the amd64 image, where
# steamcmd runs natively. On arm64 steamcmd is executed through box64's
# box32 mode, which wraps all required libraries, so the arm64 libs stage
# stays (almost) empty. BuildKit only builds the stage chain that the
# selected TARGETARCH actually references, so arm64 builds never have to
# emulate the linux/386 stage above.
FROM scratch AS libs-arm64
# Placeholder file so this nearly empty stage can be COPYed from
COPY --from=build-env /usr/local/etc/git-commit.HEAD /placeholder

FROM scratch AS libs-amd64
COPY --from=i386-libs /lib/ld-linux.so.2 /lib/ld-linux.so.2
COPY --from=i386-libs /lib/i386-linux-gnu /lib/i386-linux-gnu
COPY --from=i386-libs /usr/lib/i386-linux-gnu /usr/lib/i386-linux-gnu

FROM libs-${TARGETARCH} AS libs


FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive
COPY --from=build-env /usr/local/ /usr/local/
COPY fake-supervisord /usr/bin/supervisord
# box64 launcher wrapper used on arm64 to run the x86_64 server binary and
# the 32-bit x86 steamcmd binary through emulation. Unused on amd64.
COPY box64.sh /usr/local/bin/box64

# Copy the 32-bit x86 libraries (amd64 only) into the image. Debian trixie
# uses merged /usr, so /lib is a symlink to /usr/lib and the library files
# have to be copied through it rather than replacing it. On arm64 the libs
# stage is empty and this is a no-op - box64 provides everything steamcmd
# needs on arm64.
RUN --mount=type=bind,from=libs,target=/mnt/libs \
    if [ -e /mnt/libs/lib ]; then cp -a /mnt/libs/lib/. /lib/; fi; \
    if [ -e /mnt/libs/usr ]; then cp -a /mnt/libs/usr/. /usr/; fi

# On arm64 hosts, install box64 (with its integrated box32 mode) so the
# x86_64 Valheim server binary and the 32-bit x86 steamcmd binary can run
# on 64-bit ARM hosts such as the Raspberry Pi 4. Alongside the generic
# build, dynarec builds tuned for various Raspberry Pi models are
# installed. One is selected at runtime via ARM64_DEVICE (see box64.sh).
# This is a no-op on amd64, where all binaries run natively.
RUN set -eu; \
    if [ "$(dpkg --print-architecture)" != "arm64" ]; then \
        echo "$(dpkg --print-architecture) image - running x86 binaries natively"; \
    else \
        apt-get update; \
        apt-get -y --no-install-recommends install ca-certificates curl gnupg; \
        curl -fsSL https://ryanfortner.github.io/box64-debs/KEY.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/box64-debs-archive-keyring.gpg; \
        echo "deb [signed-by=/etc/apt/trusted.gpg.d/box64-debs-archive-keyring.gpg] https://ryanfortner.github.io/box64-debs/ ./" > /etc/apt/sources.list.d/box64.list; \
        apt-get update; \
        mkdir -p /tmp/box64dl; \
        cd /tmp/box64dl; \
        for variant in generic:box64 rpi3:box64-rpi3arm64 rpi4:box64-rpi4arm64 rpi5:box64-rpi5arm64; do \
            name="${variant%%:*}"; \
            pkg="${variant##*:}"; \
            apt-get download "$pkg"; \
            dpkg-deb -x "${pkg}"_*.deb extract; \
            cp extract/usr/local/bin/box64 "/usr/local/bin/box64-${name}"; \
            if [ -f extract/usr/local/bin/box64-bash ]; then cp extract/usr/local/bin/box64-bash "/usr/local/bin/box64-bash-${name}"; fi; \
            rm -rf extract "${pkg}"_*.deb; \
        done; \
        cd /; \
        rm -rf /tmp/box64dl; \
        printf '[steamcmd]\nBOX64_DYNAREC_BIGBLOCK=3\nBOX64_DYNAREC_CALLRET=2\nBOX64_DYNAREC_STRONGMEM=1\n' >> /etc/box64.box64rc; \
        apt-get clean; \
        rm -rf /var/lib/apt/lists/*; \
    fi; \
    chmod 755 /usr/local/bin/box64

RUN groupadd -g "${PGID:-0}" -o valheim \
    && useradd -g "${PGID:-0}" -u "${PUID:-0}" -o --create-home valheim \
    && apt-get update \
    && apt-get -y --no-install-recommends install apt-utils \
    && apt-get -y dist-upgrade \
    && apt-get -y --no-install-recommends install \
    libc6-dev \
    libsdl2-2.0-0 \
    curl \
    iproute2 \
    libcurl4 \
    ca-certificates \
    procps \
    locales \
    unzip \
    zip \
    rsync \
    openssh-client \
    jq \
    python3-minimal \
    python3-pkg-resources \
    python3-setuptools \
    libpulse-dev \
    libatomic1 \
    libc6 \
    tini \
    && echo 'LANG="en_US.UTF-8"' > /etc/default/locale \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
    && rm -f /bin/sh \
    && ln -s /bin/bash /bin/sh \
    && locale-gen \
    && update-alternatives --install /usr/bin/python python /usr/bin/python3 1 \
    && apt-get clean \
    && mkdir -p /var/spool/cron/crontabs /var/log/supervisor /opt/valheim /opt/steamcmd /home/valheim/.config/unity3d/IronGate /config /var/run/valheim \
    && ln -s /config /home/valheim/.config/unity3d/IronGate/Valheim \
    && ln -s /usr/local/bin/busybox /usr/local/bin/bc \
    && ln -s /usr/local/bin/busybox /usr/local/bin/bunzip2 \
    && ln -s /usr/local/bin/busybox /usr/local/bin/bzcat \
    && ln -s /usr/local/bin/busybox /usr/local/bin/bzip2 \
    && ln -s /usr/local/bin/busybox /usr/local/bin/crontab \
    && ln -s /usr/local/bin/busybox /usr/local/bin/httpd \
    && ln -s /usr/local/bin/busybox /usr/local/bin/iostat \
    && ln -s /usr/local/bin/busybox /usr/local/bin/killall \
    && ln -s /usr/local/bin/busybox /usr/local/bin/less \
    && ln -s /usr/local/bin/busybox /usr/local/bin/lsof \
    && ln -s /usr/local/bin/busybox /usr/local/bin/ping \
    && ln -s /usr/local/bin/busybox /usr/local/bin/ping6 \
    && ln -s /usr/local/bin/busybox /usr/local/bin/setuidgid \
    && ln -s /usr/local/bin/busybox /usr/local/bin/ssl_client \
    && ln -s /usr/local/bin/busybox /usr/local/bin/traceroute \
    && ln -s /usr/local/bin/busybox /usr/local/bin/traceroute6 \
    && ln -s /usr/local/bin/busybox /usr/local/bin/unxz \
    && ln -s /usr/local/bin/busybox /usr/local/bin/vi \
    && ln -s /usr/local/bin/busybox /usr/local/bin/wget \
    && ln -s /usr/local/bin/busybox /usr/local/bin/xz \
    && ln -s /usr/local/bin/busybox /usr/local/bin/xzcat \
    && ln -s /usr/local/bin/busybox /usr/local/bin/xxd \
    && ln -s /usr/local/bin/busybox /usr/local/sbin/crond \
    && ln -s /usr/local/bin/busybox /usr/local/sbin/mkpasswd \
    && ln -s /usr/local/bin/busybox /usr/local/sbin/syslogd \
    && curl -L -o /tmp/steamcmd_linux.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    && tar xzvf /tmp/steamcmd_linux.tar.gz -C /opt/steamcmd/ \
    && chown -R valheim:valheim /var/run/valheim \
    && chown -R root:root /opt/steamcmd \
    && chmod u=rwx,go=rx /opt/steamcmd/steamcmd.sh \
    /opt/steamcmd/linux32/steamcmd \
    /opt/steamcmd/linux32/steamerrorreporter \
    /usr/bin/supervisord \
    && cd "/opt/steamcmd" \
    && steamcmd_bootstrap_rc=0 \
    && if [ "$(dpkg --print-architecture)" = "arm64" ]; then \
           su - valheim -c "DEBUGGER=/usr/local/bin/box64 /opt/steamcmd/steamcmd.sh +login anonymous +quit" || steamcmd_bootstrap_rc=$?; \
       else \
           su - valheim -c "/opt/steamcmd/steamcmd.sh +login anonymous +quit" || steamcmd_bootstrap_rc=$?; \
       fi \
    && case "$steamcmd_bootstrap_rc" in \
           0|134|139) echo "steamcmd bootstrap exited with $steamcmd_bootstrap_rc (134/139 are steamcmd's well-known crash-after-success exit codes) - continuing" ;; \
           *) exit "$steamcmd_bootstrap_rc" ;; \
       esac \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && date --utc --iso-8601=seconds > /usr/local/etc/build.date

# arm64: place steamcmd's steamclient.so where box64/box32 look for it,
# both in the emulated library paths and in the ~/.steam/sdk* paths that
# steamclient consumers use. No-op on amd64.
RUN set -eu; \
    if [ "$(dpkg --print-architecture)" = "arm64" ]; then \
        mkdir -p /usr/lib/box64-x86_64-linux-gnu /usr/lib/box64-i386-linux-gnu \
            /usr/lib/x86_64-linux-gnu /usr/lib/i386-linux-gnu; \
        ln -sf /opt/steamcmd/linux64/steamclient.so /usr/lib/x86_64-linux-gnu/steamclient.so; \
        ln -sf /opt/steamcmd/linux64/steamclient.so /usr/lib/box64-x86_64-linux-gnu/steamclient.so; \
        ln -sf /opt/steamcmd/linux32/steamclient.so /usr/lib/i386-linux-gnu/steamclient.so; \
        ln -sf /opt/steamcmd/linux32/steamclient.so /usr/lib/box64-i386-linux-gnu/steamclient.so; \
        mkdir -p /home/valheim/.steam/sdk32 /home/valheim/.steam/sdk64; \
        ln -sf /opt/steamcmd/linux32/steamclient.so /home/valheim/.steam/sdk32/steamclient.so; \
        ln -sf /opt/steamcmd/linux64/steamclient.so /home/valheim/.steam/sdk64/steamclient.so; \
    fi

EXPOSE 2456-2458/udp
EXPOSE 9001/tcp
EXPOSE 80/tcp
WORKDIR /
CMD ["/usr/local/sbin/bootstrap"]
