// Extracts vault entries from the Markdown tables of the password list on the PC (e.g. ~/SIFRELER.md).
// "## Group" headings become tags. Columns are recognized by header (Service/Server | Address | User | Password …);
// if none match, by position (2: title, password · 3: title, user, password · 4: title, address, user, password).
// Without a title column the entry name becomes the username or address. Rows with only a name are skipped.
// Backticked values (`value`) are the actual value; the rest of the cell goes to the note. "—" means empty.
import 'vault.dart';

class ImportCandidate {
  const ImportCandidate({required this.title, this.username = '', this.password = '', this.url = '', this.notes = '', this.tags = const []});
  final String title;
  final String username;
  final String password;
  final String url;
  final String notes;
  final List<String> tags;

  /// Keep passwords out of debug output.
  @override
  String toString() => 'ImportCandidate($title)';
}

enum _Role { title, url, user, password, other }

_Role _roleOf(String header) {
  final h = header.toLowerCase().replaceAll('`', '').trim();
  bool any(List<String> words) => words.any(h.contains);
  if (any(const ['şifre', 'sifre', 'parola', 'password', 'pass', 'token', 'secret'])) return _Role.password;
  if (any(const ['kullanıcı', 'kullanici', 'user', 'e-posta', 'eposta', 'email', 'e-mail', 'login'])) return _Role.user;
  if (any(const ['adres', 'address', 'url', 'link', 'bağlantı', 'host'])) return _Role.url;
  if (h == 'ad' || any(const ['servis', 'service', 'sunucu', 'server', 'başlık', 'title', 'name', 'site', 'hesap', 'account', 'uygulama'])) return _Role.title;
  return _Role.other;
}

/// Splits a table row into cells: pipes inside backticks and `\|`-escaped pipes don't split.
List<String> splitTableRow(String line) {
  var s = line.trim();
  if (s.startsWith('|')) s = s.substring(1);
  if (s.endsWith('|') && !s.endsWith(r'\|')) s = s.substring(0, s.length - 1);
  final cells = <String>[];
  final cur = StringBuffer();
  var code = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == r'\' && i + 1 < s.length && s[i + 1] == '|') {
      cur.write('|');
      i++;
    } else if (c == '`') {
      code = !code;
      cur.write(c);
    } else if (c == '|' && !code) {
      cells.add(cur.toString().trim());
      cur.clear();
    } else {
      cur.write(c);
    }
  }
  cells.add(cur.toString().trim());
  return cells;
}

bool _isSeparator(List<String> cells) => cells.isNotEmpty && cells.every((c) => RegExp(r'^:?-{2,}:?$').hasMatch(c));

bool _empty(String s) => const {'', '—', '–', '-', '…'}.contains(s.trim());

final _code = RegExp(r'`([^`]*)`');

String _unwrap(String s) => s.replaceAllMapped(_code, (m) => m[1]!).replaceAll('**', '').trim();

/// The cell's description outside its first backticked value (empty if none). If there are several values
/// (e.g. "Web: `a` · App: `b`") they all go into the note with their context.
String _rest(String cell) {
  final all = _code.allMatches(cell).toList();
  if (all.isEmpty) return '';
  if (all.length > 1) return _unwrap(cell);
  final m = all.first;
  final r = _unwrap('${cell.substring(0, m.start)} ${cell.substring(m.end)}').replaceAll(RegExp(r'\s+'), ' ');
  return RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(r) ? r : '';
}

String _tagOf(String heading) {
  var s = heading.replaceAll(RegExp(r'[*_`]'), '').trim();
  for (final sep in const [' (', ' — ', ' – ', ' · ', ' - ', ':']) {
    final i = s.indexOf(sep);
    if (i > 0) s = s.substring(0, i);
  }
  return s.trim();
}

/// Entry candidates from the tables in a Markdown text.
List<ImportCandidate> parsePasswordMarkdown(String text) {
  final out = <ImportCandidate>[];
  String? tag;
  final lines = text.split(RegExp(r'\r?\n'));
  var i = 0;
  while (i < lines.length) {
    final line = lines[i].trim();
    final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
    if (heading != null) {
      tag = heading[1]!.length == 1 ? null : _tagOf(heading[2]!);
      i++;
      continue;
    }
    if (!line.startsWith('|') || i + 1 >= lines.length || !_isSeparator(splitTableRow(lines[i + 1]))) {
      i++;
      continue;
    }
    final header = splitTableRow(line);
    i += 2;
    var roles = header.map(_roleOf).toList();
    if (roles.every((r) => r == _Role.other)) {
      roles = switch (header.length) {
        2 => [_Role.title, _Role.password],
        3 => [_Role.title, _Role.user, _Role.password],
        4 => [_Role.title, _Role.url, _Role.user, _Role.password],
        _ => [_Role.title, for (var k = 1; k < header.length; k++) _Role.other],
      };
    }
    while (i < lines.length && lines[i].trim().startsWith('|')) {
      final cells = splitTableRow(lines[i]);
      i++;
      var title = '', user = '', pass = '', url = '';
      final notes = <String>[];
      for (var c = 0; c < cells.length && c < roles.length; c++) {
        final cell = cells[c];
        if (_empty(cell)) continue;
        final label = _unwrap(header[c]);
        final first = _code.firstMatch(cell)?[1];
        final rest = _rest(cell);
        switch (roles[c]) {
          case _Role.title:
            if (title.isEmpty) {
              title = _unwrap(cell);
            } else {
              notes.add('$label: ${_unwrap(cell)}');
            }
          case _Role.password:
            if (pass.isNotEmpty) {
              notes.add('$label: ${_unwrap(cell)}');
            } else if (first != null) {
              pass = first;
              if (rest.isNotEmpty) notes.add('$label: $rest');
            } else if (!RegExp(r'\s').hasMatch(cell.trim())) {
              pass = cell.trim();
            } else {
              notes.add('$label: ${_unwrap(cell)}'); // e.g. "okunamaz (tek yönlü özet)"
            }
          case _Role.user:
            if (user.isNotEmpty) {
              notes.add('$label: ${_unwrap(cell)}');
            } else if (first != null) {
              user = first;
              if (rest.isNotEmpty) notes.add('$label: $rest');
            } else {
              user = _unwrap(cell);
            }
          case _Role.url:
            final plain = _unwrap(cell);
            final link = RegExp(r'''https?://[^\s)`'"<>]+''').firstMatch(plain)?[0];
            if (url.isEmpty && link != null) {
              url = link;
              final r = plain.replaceFirst(link, '').trim();
              if (RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(r)) notes.add('$label: $plain');
            } else if (url.isEmpty && first != null) {
              url = first;
              if (rest.isNotEmpty) notes.add('$label: $rest');
            } else if (url.isEmpty && !RegExp(r'\s').hasMatch(plain)) {
              url = plain;
            } else {
              notes.add('$label: $plain');
            }
          case _Role.other:
            notes.add('$label: ${_unwrap(cell)}');
        }
      }
      if (pass.isEmpty && user.isEmpty && url.isEmpty && notes.isEmpty) continue; // name only: not worth an entry
      out.add(ImportCandidate(
        title: title.isNotEmpty ? title : (user.isNotEmpty ? user : (url.isNotEmpty ? url : (tag ?? '?'))),
        username: user,
        password: pass,
        url: url,
        notes: notes.join('\n'),
        tags: [?tag],
      ));
    }
  }
  return out;
}

String _key(String title, String user) => '${title.trim().toLowerCase()}\n${user.trim().toLowerCase()}';

class ImportOutcome {
  const ImportOutcome(this.entries, {required this.added, required this.updated});
  final List<VaultEntry> entries;
  final int added;
  final int updated;
}

/// Adds the selected candidates to the vault; an entry with the same title + username is updated instead of adding
/// a new one (non-empty fields are written, tags merged, note added if missing).
ImportOutcome mergeImported(List<VaultEntry> current, List<ImportCandidate> picked, DateTime now, {String Function()? newId}) {
  final entries = [...current];
  final index = {for (var i = 0; i < entries.length; i++) _key(entries[i].title, entries[i].username): i};
  var added = 0, updated = 0;
  final stamp = now.toUtc();
  for (final c in picked) {
    final k = _key(c.title, c.username);
    final at = index[k];
    if (at == null) {
      entries.add(VaultEntry(
        id: (newId ?? newVaultId)(),
        title: c.title,
        username: c.username,
        password: c.password,
        url: c.url,
        notes: c.notes,
        tags: c.tags,
        updatedAt: stamp,
      ));
      index[k] = entries.length - 1;
      added++;
      continue;
    }
    final e = entries[at];
    final next = e.copyWith(
      password: c.password.isEmpty ? null : c.password,
      url: c.url.isEmpty ? null : c.url,
      notes: c.notes.isEmpty || e.notes.contains(c.notes) ? null : (e.notes.isEmpty ? c.notes : '${e.notes}\n${c.notes}'),
      tags: {...e.tags, ...c.tags}.toList(),
    );
    final changed = next.password != e.password || next.url != e.url || next.notes != e.notes || next.tags.length != e.tags.length;
    if (changed) {
      entries[at] = next.copyWith(updatedAt: stamp);
      updated++;
    }
  }
  return ImportOutcome(entries, added: added, updated: updated);
}
