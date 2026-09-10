import 'package:flutter/material.dart';

import '../languages.dart';

/// Bottom-sheet language picker with search — 130+ languages,
/// same interaction pattern as the original's language selection sheet.
Future<Lang?> showLanguagePicker(BuildContext context, Lang current) {
  return showModalBottomSheet<Lang>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _LangPicker(current),
  );
}

class _LangPicker extends StatefulWidget {
  final Lang current;
  const _LangPicker(this.current);
  @override
  State<_LangPicker> createState() => _LangPickerState();
}

class _LangPickerState extends State<_LangPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final results = kLanguages.where((l) {
      final q = _query.trim().toLowerCase();
      if (q.isEmpty) return true;
      return l.fa.contains(q) ||
          l.native.toLowerCase().contains(q) ||
          l.code.toLowerCase().contains(q);
    }).toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.86,
      maxChildSize: 0.95,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              autofocus: false,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'جستجوی زبان…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() => _query = '')),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(children: [
              Text('${kLanguages.length} زبان',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ]),
          ),
          Expanded(
            child: ListView.builder(
              controller: controller,
              itemCount: results.length,
              itemBuilder: (context, i) {
                final l = results[i];
                final selected = l.code == widget.current.code;
                return ListTile(
                  leading: Text(l.flag, style: const TextStyle(fontSize: 22)),
                  title: Text(l.fa,
                      style: TextStyle(
                          fontWeight: selected ? FontWeight.w800 : FontWeight.w500)),
                  subtitle: Text(l.native, style: const TextStyle(fontSize: 12)),
                  trailing: selected
                      ? Icon(Icons.check_circle, color: cs.primary)
                      : Text(l.code, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                  onTap: () => Navigator.of(context).pop(l),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
