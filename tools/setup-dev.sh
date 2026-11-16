#!/usr/bin/env bash
# Installs Tiphys dev tools under ~/opt without sudo.
# The emulator and system image are NOT installed (no emulator runs on the PC).
# Run everything limited to 2 cores: taskset -c 0,1 nice -n 10 ionice -c2 -n7 ./setup-dev.sh
set -euo pipefail

OPT="$HOME/opt"
DL="$OPT/.downloads"
mkdir -p "$OPT" "$DL"

fetch() { # url file algorithm digest
  local url=$1 out=$2 algo=$3 sum=$4
  if [ ! -f "$out" ] || ! echo "$sum  $out" | "${algo}sum" -c --status; then
    curl -fL --retry 3 --max-time 3600 -o "$out" "$url"
  fi
  echo "$sum  $out" | "${algo}sum" -c
}

# JDK 17 (Temurin)
if [ ! -x "$OPT/jdk-17/bin/java" ]; then
  fetch "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.21%2B9/OpenJDK17U-jdk_x64_linux_hotspot_17.0.21_9.tar.gz" \
    "$DL/jdk17.tar.gz" sha256 8b9b611d917e3dfd8419d3566b5949226f69b052fed7e109c1368add1dfe8711
  rm -rf "$OPT/jdk-17" && mkdir -p "$OPT/jdk-17"
  tar -xzf "$DL/jdk17.tar.gz" -C "$OPT/jdk-17" --strip-components=1
fi

# Flutter 3.47.9 stable
if [ ! -x "$OPT/flutter/bin/flutter" ]; then
  fetch "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.9-stable.tar.xz" \
    "$DL/flutter.tar.xz" sha256 25ed8c3c29d51a7353f2a944310b478af8214920639524b19c50a19e6c044c5a
  rm -rf "$OPT/flutter"
  tar -xJf "$DL/flutter.tar.xz" -C "$OPT"
fi

# Android command-line tools
export ANDROID_HOME="$OPT/android-sdk"
if [ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
  fetch "https://dl.google.com/android/repository/commandlinetools-linux-16111833_latest.zip" \
    "$DL/cmdline-tools.zip" sha1 e025545c62a8e64c7559119566a569fb1dec5f60
  rm -rf "$ANDROID_HOME/cmdline-tools" && mkdir -p "$ANDROID_HOME/cmdline-tools"
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$DL/cmdline-tools.zip" "$ANDROID_HOME/cmdline-tools"
  mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
  chmod +x "$ANDROID_HOME/cmdline-tools/latest/bin/"*
fi

export JAVA_HOME="$OPT/jdk-17"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$OPT/flutter/bin:$PATH"

yes | sdkmanager --licenses >/dev/null
sdkmanager --install "platform-tools" "platforms;android-36" "build-tools;36.0.0"

flutter config --no-analytics --android-sdk "$ANDROID_HOME" --jdk-dir "$JAVA_HOME" \
  --no-enable-web --no-enable-linux-desktop --no-enable-macos-desktop --no-enable-windows-desktop
dart --disable-analytics
flutter precache --android
yes | flutter doctor --android-licenses >/dev/null || true
flutter doctor -v

# Env file: in the shell `source ~/opt/tiphys-env.sh`
cat > "$OPT/tiphys-env.sh" <<EOF
export JAVA_HOME="$JAVA_HOME"
export ANDROID_HOME="$ANDROID_HOME"
export PATH="\$JAVA_HOME/bin:\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:$OPT/flutter/bin:\$HOME/.pub-cache/bin:\$PATH"
export GRADLE_OPTS="-Dorg.gradle.workers.max=2 -Xmx2g"
EOF
echo "TAMAM"
