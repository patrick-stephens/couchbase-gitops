# Based on https://github.com/alexei-led/nsenter to get a node back-door executable
FROM debian:buster as builder

# intall gcc and supporting packages
RUN apt-get update && apt-get install -yq make gcc gettext autopoint bison libtool automake pkg-config

WORKDIR /code

# download util-linux sources
ARG UTIL_LINUX_VER=2.36.2
ADD https://github.com/karelzak/util-linux/archive/v${UTIL_LINUX_VER}.tar.gz .
RUN tar -xf v${UTIL_LINUX_VER}.tar.gz && mv util-linux-${UTIL_LINUX_VER} util-linux

# make static version
WORKDIR /code/util-linux
RUN ./autogen.sh && ./configure
RUN make LDFLAGS="--static" nsenter

#https://github.com/alexei-led/nsenter/issues/2

#v0.8.7 contains a fix for always reporting timeout errors
FROM k8s.gcr.io/node-problem-detector/node-problem-detector:v0.8.7
# For OCP: https://github.com/openshift/node-problem-detector

RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    curl \
    dnsutils \
    iptables \
    iputils-ping \
    jq \
    net-tools \
  ; \
  rm -rf /var/lib/apt/lists/*;

COPY config /config
RUN find /config -name "*.sh" -exec chmod a+x {} \;

COPY --from=builder /code/util-linux/nsenter /

ENTRYPOINT ["/node-problem-detector", "--logtostderr", "--config.custom-plugin-monitor=/config/ping-nodes.json,/config/network-problem-monitor.json,/config/uptime-plugin-monitor.json,/config/network-problem-monitor.json,/config/fd-problem-monitor.json"]
