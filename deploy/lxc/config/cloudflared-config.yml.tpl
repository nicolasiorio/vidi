# vidi cloudflared tunnel config — rendered via envsubst at provision time
# (provision.sh Phase 6.2). Substituted vars: TUNNEL_UUID, DOMAIN.

tunnel: ${TUNNEL_UUID}
credentials-file: /etc/cloudflared/vidi.json

ingress:
  - hostname: ${DOMAIN}
    service: http://127.0.0.1:3000
  - service: http_status:404
