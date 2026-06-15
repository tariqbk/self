FROM caddy:2-builder AS builder

# GOSUMDB=off avoids flaky TLS handshakes to sum.golang.org during the build
ENV GOSUMDB=off
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
