FROM alpine:3.22

RUN set -eu && \
    apk --no-cache add \
    openrc \
    tini \
    bash \
    samba \
    samba-winbind \
    tzdata \
    wsdd \
    avahi \
    dbus \
    shadow && \
    addgroup -S smb && \
    rm -f /etc/samba/smb.conf && \
    rm -rf /tmp/* /var/cache/apk/*

COPY --chmod=755 samba.sh /usr/bin/samba.sh
COPY --chmod=664 smb.conf /etc/samba/smb.default

VOLUME /storage
EXPOSE 135 137/udp 138/udp 139 445 3702/udp 5353/udp 5353 5357 5358

ENV NAME="Data"
ENV USER="samba"
ENV PASS="secret"

ENV UID=1000
ENV GID=1000
ENV RW=true

ENV WSDD=1
ENV AVAHI=1

ENV DAEMON_LIST="smbd nmbd winbindd"

HEALTHCHECK --interval=60s --timeout=15s CMD smbclient --configfile=/etc/samba.conf -L \\localhost -U % -m SMB3

ENTRYPOINT ["/sbin/tini", "--", "/usr/bin/samba.sh"]
