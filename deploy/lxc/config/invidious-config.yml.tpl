# vidi/deploy/lxc/config/invidious-config.yml.tpl
# Templated Invidious config. Rendered via `envsubst` against secrets.env
# at provision time and written to /etc/invidious/config.yml (mode 0640,
# owner invidious). Implementation lands in build Batch 2 (Task 4.3).
