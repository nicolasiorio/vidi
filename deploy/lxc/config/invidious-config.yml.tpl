# vidi/deploy/lxc/config/invidious-config.yml.tpl
# Templated Invidious config. Rendered via `envsubst` at provision time
# against /etc/invidious/secrets.env, written to /etc/invidious/config.yml
# (mode 0640, owner invidious). Invidious does not read env vars at runtime,
# so the secret values are baked into config.yml directly.

db:
  user: invidious
  password: ${POSTGRES_PASSWORD}
  host: 127.0.0.1
  port: 5432
  dbname: invidious

host_binding: 127.0.0.1
port: 3000

domain: vidi.karst.live
external_port: 443
https_only: true

hmac_key: "${HMAC_KEY}"
registration_enabled: true
login_enabled: true
captcha_enabled: false

# SERVER_SECRET_KEY is shared between Invidious (here) and companion (env).
# Must be exactly 16 chars per upstream constraint.
invidious_companion:
  - private_url: "http://127.0.0.1:8282/companion"
    public_url: "https://vidi.karst.live/companion"
invidious_companion_key: "${SERVER_SECRET_KEY}"

default_user_preferences:
  quality: hd720
  related_videos: false
  comments: ["youtube"]
