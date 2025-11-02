# syntax=docker/dockerfile:1.19@sha256:b6afd42430b15f2d2a4c5a02b919e98a525b785b1aaff16747d2f623364e39b6

####################################################################################################
# Unbound build dependencies
####################################################################################################

FROM alpine:3.22.2@sha256:4b7ce07002c69e8f3d704a9c5d6fd3053be500b7f1c69fc0d80990c2ad8dd412 AS build-base

ARG TARGETARCH

# hadolint ignore=DL3018
RUN --mount=type=cache,id=apk-cache-${TARGETARCH},target=/var/cache/apk \
	apk add --update --cache-dir=/var/cache/apk \
	binutils \
	bind-tools \
	build-base \
	ca-certificates-bundle \
	libevent-dev \
	libsodium-dev \
	nghttp2-dev \
	openssl-dev \
	hiredis-dev \
	expat-dev \
	wget

ARG NONROOT_UID=65532
ARG NONROOT_GID=65532

RUN addgroup -S -g ${NONROOT_GID} nonroot \
	&& adduser -S -g nonroot -h /home/nonroot -u ${NONROOT_UID} -D -G nonroot nonroot

####################################################################################################
# LDNS library build
####################################################################################################

FROM build-base AS ldns

WORKDIR /src

ARG LDNS_VERSION=1.8.4
# https://nlnetlabs.nl/downloads/ldns/ldns-1.8.4.tar.gz.sha256
ARG LDNS_SHA256="838b907594baaff1cd767e95466a7745998ae64bc74be038dccc62e2de2e4247"

ADD https://nlnetlabs.nl/downloads/ldns/ldns-${LDNS_VERSION}.tar.gz ldns.tar.gz

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN echo "${LDNS_SHA256}  ldns.tar.gz" | sha256sum -c - \
	&& tar -xzf ldns.tar.gz --strip-components=1

RUN ./configure \
	--prefix=/opt/usr \
	--with-drill \
	--localstatedir=/var \
	--with-ssl \
	--disable-rpath \
	--disable-shared \
	--disable-static \
	--disable-ldns-config

RUN make -j"$(nproc)" && \
	make install && \
	strip /opt/usr/bin/drill && \
	ln -s drill /opt/usr/bin/dig

####################################################################################################
# Unbound build
####################################################################################################

FROM build-base AS unbound

WORKDIR /src

ARG UNBOUND_VERSION=1.24.1
# https://nlnetlabs.nl/downloads/unbound/unbound-1.24.1.tar.gz.sha256
ARG UNBOUND_SHA256="7f2b1633e239409619ae0527f67878b0f33ae0ec0ee5a3a51c042c359ba1eeab"

ADD https://nlnetlabs.nl/downloads/unbound/unbound-${UNBOUND_VERSION}.tar.gz unbound.tar.gz

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN echo "${UNBOUND_SHA256}  unbound.tar.gz" | sha256sum -c - \
	&& tar -xzf unbound.tar.gz --strip-components=1

# https://unbound.docs.nlnetlabs.nl/en/latest/getting-started/installation.html#building-from-source-compiling
RUN ./configure \
	--prefix=/opt/usr \
	--with-conf-file=/etc/unbound/unbound.conf \
	--with-run-dir=/var/unbound \
	--with-chroot-dir=/var/unbound \
	--with-pidfile=/var/unbound/unbound.pid \
	--with-rootkey-file=/var/unbound/root.key \
	--disable-static \
	--disable-shared \
	--disable-rpath \
	--enable-dnscrypt \
	--enable-subnet \
	--enable-cachedb \
	--enable-tfo-server \
	--enable-tfo-client \
	--with-pthreads \
	--with-libevent \
	--with-libhiredis \
	--with-libnghttp2 \
	--with-ssl \
	--with-username=unbound

RUN make -j"$(nproc)" && \
	make install && \
	strip /opt/usr/sbin/unbound \
	/opt/usr/sbin/unbound-anchor \
	/opt/usr/sbin/unbound-checkconf \
	/opt/usr/sbin/unbound-control \
	/opt/usr/sbin/unbound-host

WORKDIR /var/unbound

####################################################################################################
# Root hints for Unbound
####################################################################################################

FROM build-base AS root-hints

# https://unbound.docs.nlnetlabs.nl/en/latest/manpages/unbound-anchor.html
RUN wget -q https://www.internic.net/domain/named.root -O /root.hints

####################################################################################################
# Process Unbound configuration
####################################################################################################

FROM build-base AS unbound-config

WORKDIR /etc/unbound

# Copy and process the unbound configuration
COPY rootfs_overlay/etc/unbound/ /etc/unbound/

# Fix username in unbound.conf to use nonroot instead of unbound
RUN sed -i 's/username: "unbound"/username: "nonroot"/g' /etc/unbound/unbound.conf

# Fix root-hints and root.key paths to be absolute
RUN sed -i 's|root-hints: root.hints|root-hints: /var/unbound/root.hints|g' /etc/unbound/unbound.conf && \
	sed -i 's|auto-trust-anchor-file: root.key|auto-trust-anchor-file: /var/unbound/root.key|g' /etc/unbound/unbound.conf

# Enable querying localhost so unbound can forward to dnscrypt-proxy on 127.0.0.1:5053
# Add this setting in the server section if it doesn't exist
RUN if ! grep -q "do-not-query-localhost" /etc/unbound/unbound.conf; then \
		sed -i '/^server:/a\    do-not-query-localhost: no' /etc/unbound/unbound.conf; \
	else \
		sed -i 's/do-not-query-localhost: yes/do-not-query-localhost: no/g' /etc/unbound/unbound.conf; \
	fi

####################################################################################################
# Generate Unbound root key
####################################################################################################

FROM unbound AS root-key

WORKDIR /var/unbound

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

COPY --from=root-hints /root.hints .

# Generate initial root key with the provided root hints.
# https://unbound.docs.nlnetlabs.nl/en/latest/manpages/unbound-anchor.html
# This tool exits with value 1 if the root anchor was updated using the certificate or
# if the builtin root-anchor was used. It exits with code 0 if no update was necessary,
# if the update was possible with RFC 5011 tracking, or if an error occurred.
RUN { /opt/usr/sbin/unbound-anchor -v -r root.hints -a root.key || true ; } | tee -a /dev/stderr | grep -q "success: the anchor is ok"

####################################################################################################
# DNSCrypt Proxy build
####################################################################################################

FROM --platform=$BUILDPLATFORM golang:1.25.3-alpine3.21@sha256:0c9f3e09a50a6c11714dbc37a6134fd0c474690030ed07d23a61755afd3a812f AS dnscrypt-build

WORKDIR /src

# renovate: datasource=github-tags depName=DNSCrypt/dnscrypt-proxy
ARG DNSCRYPT_PROXY_VERSION=2.1.14

ADD https://github.com/DNSCrypt/dnscrypt-proxy/archive/${DNSCRYPT_PROXY_VERSION}.tar.gz /tmp/dnscrypt-proxy.tar.gz

RUN tar xzf /tmp/dnscrypt-proxy.tar.gz --strip 1

WORKDIR /src/dnscrypt-proxy

ARG TARGETOS TARGETARCH TARGETVARIANT

# Update all Go modules to latest compatible versions
# This ensures security patches (e.g., quic-go CVE-2025-59530) are applied
RUN go get -u ./... && \
    go mod tidy && \
    go mod vendor

RUN --mount=type=cache,target=/home/nonroot/.cache/go-build,uid=65532,gid=65532 \
    --mount=type=cache,target=/go/pkg \
	CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH GOARM=${TARGETVARIANT#v} go build -v -ldflags="-s -w" -mod vendor

WORKDIR /config

RUN cp -a /src/dnscrypt-proxy/example-* ./

COPY ./configs/dnscrypt-unbound/dnscrypt-proxy.toml ./

ARG NONROOT_UID=65532
ARG NONROOT_GID=65532

RUN addgroup -S -g ${NONROOT_GID} nonroot \
	&& adduser -S -g nonroot -h /home/nonroot -u ${NONROOT_UID} -D -G nonroot nonroot

####################################################################################################
# DNSCrypt Proxy config example
####################################################################################################

FROM scratch AS conf-example

# docker build . --target conf-example --output .
COPY --from=dnscrypt-build /config/example-dnscrypt-proxy.toml /dnscrypt-proxy.toml.example

####################################################################################################
# DNS Probe build
####################################################################################################

FROM --platform=$BUILDPLATFORM golang:1.25.3-alpine3.21@sha256:0c9f3e09a50a6c11714dbc37a6134fd0c474690030ed07d23a61755afd3a812f AS probe

WORKDIR /src/dnsprobe

ARG TARGETOS TARGETARCH TARGETVARIANT

COPY dnsprobe/ ./

RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH GOARM=${TARGETVARIANT#v} go build -o /usr/local/bin/dnsprobe .

####################################################################################################
# Launcher build (starts both dnscrypt-proxy and unbound)
####################################################################################################

FROM --platform=$BUILDPLATFORM golang:1.25.3-alpine3.21@sha256:0c9f3e09a50a6c11714dbc37a6134fd0c474690030ed07d23a61755afd3a812f AS launcher

WORKDIR /src/launcher

ARG TARGETOS TARGETARCH TARGETVARIANT

COPY launcher/ ./

RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH GOARM=${TARGETVARIANT#v} go build -o /usr/local/bin/launcher .

####################################################################################################
# Healthcheck build
####################################################################################################

FROM --platform=$BUILDPLATFORM golang:1.25.3-alpine3.21@sha256:0c9f3e09a50a6c11714dbc37a6134fd0c474690030ed07d23a61755afd3a812f AS healthcheck

WORKDIR /src/healthcheck

ARG TARGETOS TARGETARCH TARGETVARIANT

COPY healthcheck/ ./

RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH GOARM=${TARGETVARIANT#v} go build -o /usr/local/bin/healthcheck .

####################################################################################################
# Final stage - combine everything
####################################################################################################

FROM scratch

# Copy base libraries (musl, gcc, crypto, ssl)
COPY --from=build-base /lib/ld-musl*.so.1 /lib/
COPY --from=build-base /usr/lib/libgcc_s.so.1 /usr/lib/
COPY --from=build-base /usr/lib/libcrypto.so.3 /usr/lib/libssl.so.3 /usr/lib/
COPY --from=build-base /usr/lib/libsodium.so.* /usr/lib/libevent-2.1.so.* /usr/lib/libexpat.so.* /usr/lib/libhiredis.so.* /usr/lib/libnghttp2.so.* /usr/lib/

# Copy certificates
COPY --from=build-base /etc/ssl/ /etc/ssl/
COPY --from=dnscrypt-build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy system files (users, groups)
COPY --from=build-base /etc/passwd /etc/group /etc/

# Copy Unbound binaries
COPY --from=unbound /opt/usr/sbin/ /usr/sbin/

# Copy LDNS tools (drill, dig)
COPY --from=ldns /opt/usr/bin/ /usr/bin/

# Copy DNSCrypt Proxy, DNS Probe, Launcher, and Healthcheck
COPY --from=dnscrypt-build /src/dnscrypt-proxy/dnscrypt-proxy /usr/local/bin/
COPY --from=probe /usr/local/bin/dnsprobe /usr/local/bin/
COPY --from=launcher /usr/local/bin/launcher /usr/local/bin/launcher
COPY --from=healthcheck /usr/local/bin/healthcheck /usr/local/bin/healthcheck

# Copy DNSCrypt Proxy config
COPY --from=dnscrypt-build --chown=nonroot:nonroot /config /config

# Copy Unbound root key and hints
COPY --from=root-key --chown=nonroot:nonroot /var/unbound/root.hints /var/unbound/root.hints
COPY --from=root-key --chown=nonroot:nonroot /var/unbound/root.key /var/unbound/root.key

# Copy processed Unbound configuration
COPY --from=unbound-config --chown=nonroot:nonroot /etc/unbound/ /etc/unbound/

# Set ownership for unbound directories and home
COPY --from=build-base --chown=nonroot:nonroot /home/nonroot /home/nonroot

USER nonroot

ENV PATH=$PATH:/usr/local/bin:/usr/sbin:/usr/bin

# Health check verifies both unbound (port 53) and dnscrypt-proxy (port 5053) are responding
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["/usr/local/bin/healthcheck"]

ENTRYPOINT [ "/usr/local/bin/launcher" ]