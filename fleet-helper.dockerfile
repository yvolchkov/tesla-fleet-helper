FROM ubuntu:latest

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl debian-keyring debian-archive-keyring apt-transport-https ca-certificates gpg \
    # \
    # install cloudflared \
    && arch="$(dpkg --print-architecture)" \
    && curl -L --output cloudflared.deb \
        https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-"${arch}".deb \
    && dpkg -i cloudflared.deb \
    # \
    # Add caddy repo \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list \
    # \
    # Install the rest
    && apt-get update && apt-get install -y --no-install-recommends \
        caddy jq \
    # \
    # Cleanup\
    && rm -rf /var/lib/apt/lists/*

COPY Caddyfile /root/Caddyfile
COPY Caddyfile-nocf /root/Caddyfile-nocf

COPY fleet-helper.sh /usr/bin/fleet-helper

ENTRYPOINT [ "/usr/bin/fleet-helper" ]
