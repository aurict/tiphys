// Add / edit a database connection (PLAN.md §13.2, D-1): from a discovered container (wizard) or by hand. The read
// credential is either a dedicated user + password (recommended) or `fromContainerEnv` — the container's own
// superuser, with a prominent warning. An optional separate write user is used by the write mode. Passwords live only
// in the text fields until they are sent; an empty password field keeps the stored one (edit).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import 'db_data.dart';
import 'db_editor.dart' show confirmSuperuserReads;
import 'db_result_view.dart';
import 'db_texts.dart';

class DbFormArgs {
  const DbFormArgs({required this.hostId, this.existing, this.container, this.readRole});
  final String hostId;

  /// Prefill the PostgreSQL read role (from the read-only role helper, once the role was created).
  final String? readRole;

  /// Edit this connection.
  final DbConnection? existing;

  /// Create from this discovered container.
  final DbContainer? container;
}

/// "container" | "host" | "sqlite"
typedef _TargetKind = String;

class DbFormScreen extends ConsumerStatefulWidget {
  const DbFormScreen({super.key, required this.args});
  final DbFormArgs args;

  @override
  ConsumerState<DbFormScreen> createState() => _DbFormScreenState();
}

class _DbFormScreenState extends ConsumerState<DbFormScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _container = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _path = TextEditingController();
  final _database = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _writeUser = TextEditingController();
  final _writePassword = TextEditingController();
  final _networkText = TextEditingController();
  final _readRole = TextEditingController();
  bool _allowSuperuserReads = false;
  String _engine = 'postgres';
  _TargetKind _kind = 'container';
  String? _network;
  bool _fromEnv = false;
  bool _writeSeparate = false;
  bool _saving = false;
  Object? _error;

  DbConnection? get _existing => widget.args.existing;
  DbContainer? get _fromContainer => widget.args.container;
  bool get _editing => _existing != null;

  @override
  void initState() {
    super.initState();
    final e = _existing, c = _fromContainer;
    if (e != null) {
      _name.text = e.name;
      _engine = e.engine;
      _database.text = e.database ?? '';
      final t = e.target;
      if (t['container'] != null) {
        _kind = 'container';
        _container.text = '${t['container']}';
        _network = t['network'] as String?;
        _networkText.text = _network ?? '';
      } else if (t['host'] != null) {
        _kind = 'host';
        _host.text = '${t['host']}';
      } else {
        _kind = 'sqlite';
        _path.text = '${t['path'] ?? ''}';
      }
      if (t['port'] != null) _port.text = '${t['port']}';
      _fromEnv = e.readCredential?.fromEnv ?? false;
      _user.text = e.readCredential?.user ?? '';
      _writeSeparate = e.writeCredential != null;
      _writeUser.text = e.writeCredential?.user ?? '';
      _readRole.text = e.readRole ?? '';
      _allowSuperuserReads = e.allowSuperuserReads;
    } else if (c != null) {
      _name.text = c.container;
      _engine = c.engine;
      _container.text = c.container;
      if (c.networks.length == 1) _network = c.networks.first.name;
    }
    if (widget.args.readRole != null) _readRole.text = widget.args.readRole!;
  }

  @override
  void dispose() {
    for (final c in [_name, _container, _host, _port, _path, _database, _user, _password, _writeUser, _writePassword, _networkText, _readRole]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> _target() {
    final port = int.tryParse(_port.text.trim());
    final c0 = _fromContainer;
    return switch (_kind) {
      'sqlite' => {'path': _path.text.trim()},
      'host' => {'host': _host.text.trim(), 'port': ?port},
      _ => {'container': _container.text.trim(), if (_network != null && _network!.isNotEmpty) 'network': _network else if (c0 == null && _networkText.text.trim().isNotEmpty) 'network': _networkText.text.trim(), 'port': ?port},
    };
  }

  /// `{user, password?}`; a blank password is omitted (a new connection without one, or keep the stored one on edit).
  Map<String, dynamic> _credential(TextEditingController user, TextEditingController password) => {'user': user.text.trim(), if (password.text.isNotEmpty) 'password': password.text};

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false) || _saving) return;
    final l = AppLocalizations.of(context);
    final sqlite = _engine == 'sqlite';
    final db = _database.text.trim();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final body = <String, dynamic>{
        'name': _name.text.trim(),
        'target': _target(),
        if (_editing) 'database': db.isEmpty ? null : db else if (db.isNotEmpty) 'database': db,
        if (!sqlite) 'readCredential': _fromEnv ? {'fromContainerEnv': true} : _credential(_user, _password),
        if (!sqlite && _writeSeparate) 'writeCredential': _credential(_writeUser, _writePassword),
        if (!sqlite && !_writeSeparate && _existing?.writeCredential != null) 'writeCredential': null,
        if (!_editing) 'engine': _engine,
        // PostgreSQL read access: a read role (an empty field removes it), or superuser reads allowed.
        if (_engine == 'postgres') ...{
          if (_readRole.text.trim().isNotEmpty) 'readRole': _readRole.text.trim() else if (_existing?.readRole != null) 'readRole': null,
          if (_allowSuperuserReads || _existing?.allowSuperuserReads == true) 'allowSuperuserReads': _allowSuperuserReads,
        },
      };
      if (_editing) {
        await agentCall(ref, widget.args.hostId, 'PATCH', '/v1/db/connections/${_existing!.id}', body);
      } else {
        await agentCall(ref, widget.args.hostId, 'POST', '/v1/db/connections', body);
      }
      ref.invalidate(dbConnectionsProvider(widget.args.hostId));
      if (_fromContainer != null) ref.invalidate(dbDiscoverProvider(widget.args.hostId));
      if (!mounted) return;
      toast(context, l.dbSaved);
      final router = GoRouter.of(context);
      router.pop();
      if (_fromContainer != null && router.canPop()) router.pop();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final sqlite = _engine == 'sqlite';
    final c = _fromContainer;
    final envOk = c == null ? _kind == 'container' : c.containerEnvCredential;
    final storedRead = _existing?.readCredential;
    // FLAG_SECURE: passwords are typed here.
    return DbSecure(
      child: SettingsPage(
      title: _editing ? l.dbFormEdit : l.dbFormNew,
      onSave: _save,
      saving: _saving,
      children: [
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FieldCard(
                children: [
                  TField(controller: _name, label: l.dbFieldName, validator: requiredV(l)),
                  if (!_editing && c == null)
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: _engine,
                      decoration: InputDecoration(labelText: l.dbFieldEngine),
                      items: [
                        for (final e in const ['postgres', 'mysql', 'mariadb', 'sqlite']) DropdownMenuItem(value: e, child: Text(dbEngineName(e))),
                      ],
                      onChanged: (v) => setState(() {
                        _engine = v ?? 'postgres';
                        _kind = _engine == 'sqlite' ? 'sqlite' : (_kind == 'sqlite' ? 'container' : _kind);
                        if (_engine == 'sqlite') _fromEnv = false;
                      }),
                    )
                  else
                    InputDecorator(
                      decoration: InputDecoration(labelText: l.dbFieldEngine),
                      child: Text(dbEngineName(_engine)),
                    ),
                  if (c != null) Text(l.dbFromContainer(c.container, '${c.image}${c.version.isNotEmpty && !c.image.contains(':') ? ':${c.version}' : ''}'), style: tt.bodySmall),
                ],
              ),
              if (!sqlite) ...[
                SectionLabel(l.dbFieldTarget),
                if (c == null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SegmentedButton<String>(
                      segments: [
                        ButtonSegment(value: 'container', label: Text(l.dbTargetContainer)),
                        ButtonSegment(value: 'host', label: Text(l.dbTargetHost)),
                      ],
                      selected: {_kind},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) => setState(() {
                        _kind = s.first;
                        if (_kind == 'host') _fromEnv = false;
                      }),
                    ),
                  ),
              ] else
                SectionLabel(l.dbFieldTarget),
              FieldCard(
                children: [
                  if (_kind == 'container') ...[
                    TField(controller: _container, label: l.dbFieldContainer, mono: true, validator: requiredV(l), enabled: c == null),
                    if (c != null && c.networks.length > 1)
                      DropdownButtonFormField<String?>(
                        isExpanded: true,
                        initialValue: _network,
                        decoration: InputDecoration(labelText: l.dbFieldNetwork),
                        items: [
                          DropdownMenuItem(value: null, child: Text(l.dbNetworkAuto)),
                          for (final n in c.networks) DropdownMenuItem(value: n.name, child: Text(n.ip == null ? n.name : '${n.name} (${n.ip})')),
                        ],
                        onChanged: (v) => setState(() => _network = v),
                      )
                    else if (c == null)
                      TField(controller: _networkText, label: l.dbFieldNetwork, mono: true, hint: l.dbNetworkAuto),
                    TField(controller: _port, label: l.dbFieldPort, keyboardType: TextInputType.number, validator: _portV(l)),
                  ] else if (_kind == 'host') ...[
                    TField(controller: _host, label: l.dbFieldHost, mono: true, validator: requiredV(l)),
                    TField(controller: _port, label: l.dbFieldPort, keyboardType: TextInputType.number, validator: _portV(l)),
                  ] else
                    TField(controller: _path, label: l.dbFieldPath, mono: true, validator: requiredV(l), helper: l.dbFieldPathHint),
                  TField(controller: _database, label: l.dbFieldDatabase, mono: true, hint: l.dbDatabaseHint),
                ],
              ),
              if (!sqlite) ...[
                SectionLabel(l.dbCredentialTitle),
                ChoiceSection<bool>(options: [(false, l.dbCredPassword), if (envOk || _fromEnv) (true, l.dbCredEnv)], value: _fromEnv, onChanged: (v) => setState(() => _fromEnv = v)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                  child: Text(_fromEnv ? l.dbCredEnvHint : l.dbCredPasswordHint, style: tt.bodySmall),
                ),
                if (c != null && !c.containerEnvCredential)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: DbNote(l.dbEnvUnavailable, icon: LucideIcons.info),
                  ),
                if (_fromEnv)
                  Semantics(
                    container: true,
                    label: l.dbSuperuserWarnTitle,
                    child: DbNote(l.dbSuperuserWarnBody, title: l.dbSuperuserWarnTitle, color: t.danger, icon: LucideIcons.shieldAlert),
                  )
                else
                  FieldCard(
                    children: [
                      TField(controller: _user, label: l.dbFieldUser, mono: true, validator: requiredV(l)),
                      TField(
                        controller: _password,
                        label: l.dbFieldPassword,
                        obscure: true,
                        helper: storedRead != null && storedRead.hasPassword ? l.dbPasswordKept : null,
                        validator: (v) => (!_editing || storedRead == null || storedRead.fromEnv || !storedRead.hasPassword) && v.isEmpty ? l.commonRequired : null,
                      ),
                    ],
                  ),
                SectionLabel(l.dbWriteCredTitle),
                TCard(
                  radius: TiphysTokens.radiusList,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: SwitchListTile(value: _writeSeparate, onChanged: (v) => setState(() => _writeSeparate = v), title: Text(l.dbWriteCredSwitch), subtitle: Text(l.dbWriteCredHint), contentPadding: const EdgeInsets.symmetric(horizontal: 8)),
                ),
                if (_writeSeparate)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: FieldCard(
                      children: [
                        TField(controller: _writeUser, label: l.dbFieldUser, mono: true, validator: requiredV(l)),
                        TField(
                          controller: _writePassword,
                          label: l.dbFieldPassword,
                          obscure: true,
                          helper: _existing?.writeCredential?.hasPassword == true ? l.dbPasswordKept : null,
                          validator: (v) => _existing?.writeCredential?.hasPassword == true || v.isNotEmpty ? null : l.commonRequired,
                        ),
                      ],
                    ),
                  ),
              ],
              if (_engine == 'postgres') ...[
                SectionLabel(l.dbReadAccessTitle),
                FieldCard(
                  children: [
                    TField(controller: _readRole, label: l.dbFieldReadRole, mono: true, helper: l.dbReadRoleHint),
                  ],
                ),
                const SizedBox(height: 8),
                TCard(
                  radius: TiphysTokens.radiusList,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  borderColor: _allowSuperuserReads ? t.danger : null,
                  child: SwitchListTile(
                    value: _allowSuperuserReads,
                    activeThumbColor: t.danger,
                    onChanged: (v) async {
                      if (v && !await confirmSuperuserReads(context, _name.text.trim())) return;
                      if (mounted) setState(() => _allowSuperuserReads = v);
                    },
                    title: Text(l.dbAcceptRiskBtn),
                    subtitle: Text(l.dbAllowSuperuserReadsHint),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: DbNote(agentErrorText(l, _error!), color: t.danger),
                ),
            ],
          ),
        ),
      ],
      ),
    );
  }

  String? Function(String) _portV(AppLocalizations l) =>
      (v) => v.trim().isEmpty ? null : intV(1, 65535)(v);
}
