// Which optional platform features this build has. Android has everything. iOS has no UnifiedPush and none of the
// tiphys_native extras (FLAG_SECURE, Moonlight launch, H.264 decoder). Desktop builds (Linux, Windows, macOS) have no
// share intake, and only macOS has a camera scanner: elsewhere pairing works by pasting the code.
// Based on defaultTargetPlatform, so tests (Android by default) can switch it with debugDefaultTargetPlatformOverride.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

bool get hasUnifiedPush => defaultTargetPlatform == TargetPlatform.android;

/// The Android-only plugin packages/tiphys_native (sensitive clipboard, FLAG_SECURE, H.264 decoder, Moonlight launch).
bool get hasTiphysNative => defaultTargetPlatform == TargetPlatform.android;

bool get hasQrScanner => const {TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.macOS}.contains(defaultTargetPlatform);

bool get isDesktopPlatform => const {TargetPlatform.linux, TargetPlatform.windows, TargetPlatform.macOS}.contains(defaultTargetPlatform);

/// Where the profile and app state live: the documents folder on phones (as before), the per-app support folder on
/// desktops (not the user's visible Documents).
Future<Directory> appDataDirectory() => isDesktopPlatform ? getApplicationSupportDirectory() : getApplicationDocumentsDirectory();
