// Project links and the agent install commands shown in the app (setup wizard, notification settings). Kept in one
// place so a fork or a moved repository only changes this file. Must match docs/getting-started.md.

const kRepoUrl = 'https://github.com/aurict/tiphys';
const kRawBase = 'https://raw.githubusercontent.com/aurict/tiphys/main';
const kDocsBase = '$kRepoUrl/blob/main/docs';

/// Tailscale's download page (it picks the right store for the phone).
const kTailscaleDownloadUrl = 'https://tailscale.com/download';

/// Docs: notifications while the app is closed (ntfy / UnifiedPush) and the foreground-only mode.
const kDocsNotifications = '$kDocsBase/features/notifications.md#notifications-without-ntfy';
const kDocsGettingStarted = '$kDocsBase/getting-started.md';
const kDocsDocker = '$kRepoUrl/blob/main/packaging/README.md#docker-servers';

/// Operating systems the setup wizard offers.
enum InstallTarget { linux, macos, windows, docker }

/// The one-command install for each target (docs/getting-started.md › The easy way). Docker has no published image,
/// so its "command" builds and starts the image from a checkout (packaging/README.md › Docker).
const kInstallCommands = <InstallTarget, String>{
  InstallTarget.linux: 'curl -fsSL $kRawBase/install.sh | sh',
  InstallTarget.macos: 'curl -fsSL $kRawBase/install.sh | sh',
  InstallTarget.windows: 'irm $kRawBase/install.ps1 | iex',
  InstallTarget.docker: 'git clone $kRepoUrl.git && cd tiphys\n'
      'docker build -f packaging/docker/Dockerfile -t tiphys-agent .\n'
      'docker run -d --name tiphys --restart unless-stopped --network host --read-only --tmpfs /tmp \\\n'
      '  -v tiphys-config:/config -v /var/run/docker.sock:/var/run/docker.sock \\\n'
      '  --group-add "\$(stat -c %g /var/run/docker.sock)" -e TIPHYS_NAME=\$(hostname) tiphys-agent\n'
      'sudo tailscale serve --bg --https=7443 http://127.0.0.1:7443\n'
      'docker exec -it tiphys tiphys-agent pair --url https://\$(hostname).<tailnet>.ts.net:7443',
};
