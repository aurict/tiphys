#!/bin/sh
# The agent runs as your user (a systemd *user* service), so nothing is started for you here.
cat <<'EOF'
Tiphys agent installed. As your normal user (not root):
  tiphys-agent init --detect
  systemctl --user enable --now tiphys-agent
  sudo tailscale serve --bg --https=7443 http://127.0.0.1:7443
  tiphys-agent pair
Servers (keep it running while logged out): sudo loginctl enable-linger <user>
Check the install: tiphys-agent doctor
EOF
