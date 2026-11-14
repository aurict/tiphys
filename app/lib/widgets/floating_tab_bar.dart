// Ortada yüzen hap biçimli alt bar (Grafit Cam tasarımındaki gibi). Koyu temada buzlu cam.
import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class TabItem {
  const TabItem({required this.icon, required this.label});
  final IconData icon;
  final String label;
}

class FloatingTabBar extends StatelessWidget {
  const FloatingTabBar({super.key, required this.items, required this.index, required this.onSelect});
  final List<TabItem> items;
  final int index;
  final ValueChanged<int> onSelect;

  static const height = 62.0;
  static const bottomGap = 26.0;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bar = Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: t.tabBar,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: t.tabBarBorder),
        boxShadow: [
          BoxShadow(color: t.isDark ? const Color(0x99000000) : const Color(0x4D111114), blurRadius: 30, offset: const Offset(0, 12)),
        ],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          _TabButton(item: items[i], selected: i == index, onTap: () => onSelect(i)),
        ],
      ]),
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(filter: ImageFilter.blur(sigmaX: t.isDark ? 24 : 20, sigmaY: t.isDark ? 24 : 20), child: bar),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({required this.item, required this.selected, required this.onTap});
  final TabItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: Tooltip(
        message: item.label,
        excludeFromSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            customBorder: const StadiumBorder(),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 54,
              height: 48,
              decoration: BoxDecoration(color: selected ? t.tabActive : Colors.transparent, borderRadius: BorderRadius.circular(999)),
              child: Icon(item.icon, size: 22, color: selected ? t.tabActiveIcon : t.tabIcon),
            ),
          ),
        ),
      ),
    );
  }
}
