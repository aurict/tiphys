// Basit metin düzenleyici (SFTP): dosyayı açar, düzenler, kaydeder. Kaydetmeden önce dosya başka biri
// tarafından değiştirildiyse sorar. UTF-8 olmayan (ikili) dosyalar açılmaz.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/ssh/remote_files.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';

class TextEditorScreen extends StatefulWidget {
  const TextEditorScreen({super.key, required this.files, required this.path, required this.name});
  final RemoteFiles files;
  final String path;
  final String name;

  /// Düzenlenebilecek en büyük dosya.
  static const maxBytes = 1024 * 1024;

  @override
  State<TextEditorScreen> createState() => _TextEditorScreenState();
}

class _TextEditorScreenState extends State<TextEditorScreen> {
  final _text = TextEditingController();
  Uint8List? _original;
  Object? _error;
  bool _saving = false;
  bool _dirty = false;
  bool _wrap = true;

  @override
  void initState() {
    super.initState();
    _load();
    _text.addListener(() {
      if (_original != null && !_dirty) setState(() => _dirty = true);
    });
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await widget.files.read(widget.path, maxBytes: TextEditorScreen.maxBytes + 1);
      if (data.length > TextEditorScreen.maxBytes) throw const FormatException('too large');
      final text = utf8.decode(data); // ikili dosyada FormatException
      if (!mounted) return;
      setState(() {
        _original = data;
        _text.text = text;
        _dirty = false;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    setState(() => _saving = true);
    try {
      final now = await widget.files.read(widget.path, maxBytes: TextEditorScreen.maxBytes + 1);
      if (!_same(now, _original!) && mounted) {
        if (!await confirmDialog(context, message: l.editorChangedOnDisk, confirmLabel: l.editorOverwrite, destructive: true)) return;
      }
      final bytes = Uint8List.fromList(utf8.encode(_text.text));
      await widget.files.write(widget.path, bytes);
      _original = bytes;
      if (!mounted) return;
      setState(() => _dirty = false);
      toast(context, l.editorSaved);
    } catch (e) {
      if (mounted) toast(context, '${l.commonError}: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final field = TextField(
      controller: _text,
      maxLines: null,
      expands: true,
      keyboardType: TextInputType.multiline,
      autocorrect: false,
      enableSuggestions: false,
      textAlignVertical: TextAlignVertical.top,
      style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13, height: 1.4),
      decoration: const InputDecoration(border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none, filled: false, contentPadding: EdgeInsets.all(12)),
    );
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await confirmDialog(context, message: l.editorDiscardChanges, confirmLabel: l.editorDiscard, destructive: true) && context.mounted) {
          Navigator.of(context).pop(false);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_dirty ? '${widget.name} •' : widget.name, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: l.editorWrap,
              isSelected: _wrap,
              icon: const Icon(LucideIcons.wrapText),
              onPressed: () => setState(() => _wrap = !_wrap),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton(
                onPressed: _original == null || _saving || !_dirty ? null : _save,
                child: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Text(l.commonSave),
              ),
            ),
          ],
        ),
        body: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error is FormatException ? l.editorNotText : '${l.commonError}: $_error', textAlign: TextAlign.center, style: TextStyle(color: t.textSecondary)),
                ),
              )
            : _original == null
                ? const Center(child: CircularProgressIndicator())
                : _wrap
                    ? field
                    : LayoutBuilder(
                        builder: (c, box) => SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(width: box.maxWidth * 3, height: box.maxHeight, child: field),
                        ),
                      ),
      ),
    );
  }
}
