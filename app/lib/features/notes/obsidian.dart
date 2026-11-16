// Quick note to Obsidian: the note is written to the Obsidian app on the phone via an `obsidian://new` link.
// Tiphys doesn't write to the vault directly; Obsidian saves the note, LiveSync encrypts and syncs it (end-to-end
// encryption is preserved).
// Link format (https://help.obsidian.md/uri): values fully encoded ("/" → %2F, space → %20; not "+"),
// `file` is the path relative to the vault root (no extension), `silent` doesn't open the note, `append` appends if
// it exists (otherwise creates it).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/profile/model.dart';

/// Longest note (characters) the URI can safely carry on Android.
const obsidianMaxChars = 50000;

/// Characters Obsidian rejects in file names or that break links.
final _badName = RegExp(r'[\\/:*?"<>|#^\[\]]');

String _two(int n) => n.toString().padLeft(2, '0');

/// "Günlük/YYYY-MM-DD" → "Günlük/2026-11-14".
String dailyNotePath(String pattern, DateTime now) => pattern
    .replaceAll('YYYY', '${now.year}')
    .replaceAll('MM', _two(now.month))
    .replaceAll('DD', _two(now.day))
    .split('/')
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .join('/');

/// Note title: the given title or the first non-empty line (Markdown heading marks and forbidden characters removed,
/// at most 60 characters); if empty, a timestamp ("Not 2026-11-14 14.05").
String noteTitle(String text, DateTime now, {String? title}) {
  String clean(String s) => s.replaceFirst(RegExp(r'^\s*#+\s*'), '').replaceAll(_badName, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  var t = clean(title ?? '');
  if (t.isEmpty) t = clean(text.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => ''));
  // A name starting with a dot becomes a hidden file; a trailing dot causes problems on Android/Windows.
  t = t.replaceAll(RegExp(r'^\.+|\.+$'), '').trim();
  if (t.length > 60) t = t.substring(0, 60).trimRight();
  return t.isEmpty ? 'Not ${now.year}-${_two(now.month)}-${_two(now.day)} ${_two(now.hour)}.${_two(now.minute)}' : t;
}

/// The note's path inside the vault (no extension): new note → "folder/title", daily note → pattern.
String obsidianNotePath(ObsidianConfig c, {required String text, required DateTime now, String? title, bool? daily}) {
  if (daily ?? c.mode == 'dailyNote') return dailyNotePath(c.dailyNotePath, now);
  final folder = c.folder.split('/').map((s) => s.trim()).where((s) => s.isNotEmpty).join('/');
  final name = noteTitle(text, now, title: title);
  return folder.isEmpty ? name : '$folder/$name';
}

/// `obsidian://new?vault=…&file=…&content=…&silent=true[&append=true]`
Uri obsidianUri(ObsidianConfig c, {required String text, required DateTime now, String? title, bool? daily}) {
  final isDaily = daily ?? c.mode == 'dailyNote';
  final file = obsidianNotePath(c, text: text, now: now, title: title, daily: isDaily);
  final q = [
    'vault=${Uri.encodeComponent(c.vault)}',
    'file=${Uri.encodeComponent(file)}',
    'content=${Uri.encodeComponent(text)}',
    if (isDaily) 'append=true',
    'silent=true',
  ];
  return Uri.parse('obsidian://new?${q.join('&')}');
}

/// Opens the link; false if Obsidian isn't installed (replaced in tests).
final obsidianLauncherProvider = Provider<Future<bool> Function(Uri)>((ref) => (uri) async {
      try {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      } on PlatformException {
        return false;
      }
    });

/// Opens the quick note screen (optionally) with prefilled text: a Claude answer, a log line, terminal screen…
void openQuickNote(BuildContext context, {String text = '', String? title}) =>
    GoRouter.of(context).push('/note', extra: QuickNoteArgs(text: text, title: title));

class QuickNoteArgs {
  const QuickNoteArgs({this.text = '', this.title});
  final String text;
  final String? title;
}
