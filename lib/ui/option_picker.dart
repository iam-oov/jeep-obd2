import 'package:flutter/material.dart';

/// Filters [options] by the text typed in the search box.
/// With [yearMode]: 1-2 digits match the end ("98" -> 1998),
/// 3-4 digits match the start ("200" -> 2000-2009). Otherwise, a case-insensitive "contains".
List<String> filterOptions(List<String> options, String query, {bool yearMode = false}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return options;
  if (yearMode) {
    return options.where((o) => q.length <= 2 ? o.endsWith(q) : o.startsWith(q)).toList();
  }
  return options.where((o) => o.toLowerCase().contains(q)).toList();
}

/// Bottom sheet to pick an option: search box on top, list below, so
/// the keyboard never covers what is being typed.
///
/// Returns the chosen option, the typed text (if [allowCustom] and the
/// "Usar «…»" row is tapped), `''` if [clearLabel] is tapped, or null if closed.
Future<String?> showOptionPicker(
  BuildContext context, {
  required String title,
  required List<String> options,
  String? current,
  bool allowCustom = true,
  bool yearMode = false,
  String? clearLabel,
  String? note,
  TextInputType keyboardType = TextInputType.text,
}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _OptionPicker(
        title: title,
        options: options,
        current: current,
        allowCustom: allowCustom,
        yearMode: yearMode,
        clearLabel: clearLabel,
        note: note,
        keyboardType: keyboardType,
      ),
    );

class _OptionPicker extends StatefulWidget {
  const _OptionPicker({
    required this.title,
    required this.options,
    required this.current,
    required this.allowCustom,
    required this.yearMode,
    required this.clearLabel,
    required this.note,
    required this.keyboardType,
  });

  final String title;
  final List<String> options;
  final String? current;
  final bool allowCustom;
  final bool yearMode;
  final String? clearLabel;
  final String? note;
  final TextInputType keyboardType;

  @override
  State<_OptionPicker> createState() => _OptionPickerState();
}

class _OptionPickerState extends State<_OptionPicker> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _submit(List<String> hits) {
    final q = _query.text.trim();
    if (hits.isNotEmpty && q.isNotEmpty) {
      Navigator.pop(context, hits.first);
    } else if (q.isNotEmpty && widget.allowCustom) {
      Navigator.pop(context, q);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hits = filterOptions(widget.options, _query.text, yearMode: widget.yearMode);
    final q = _query.text.trim();
    final exact = widget.options.any((o) => o.toLowerCase() == q.toLowerCase());
    final showCustom = widget.allowCustom && q.isNotEmpty && !exact;
    final height = MediaQuery.sizeOf(context).height * 0.75;

    return Padding(
      // Lift the sheet above the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(widget.title, style: theme.textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                key: const Key('picker-search'),
                controller: _query,
                autofocus: true,
                keyboardType: widget.keyboardType,
                textInputAction: TextInputAction.done,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: widget.allowCustom ? 'Busca o escribe' : 'Busca',
                  helperText: widget.note,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(hits),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  if (showCustom && hits.isEmpty)
                    ListTile(
                      key: const Key('picker-custom'),
                      leading: const Icon(Icons.edit),
                      title: Text('Usar «$q»'),
                      subtitle: hits.isEmpty ? const Text('No está en la lista') : null,
                      onTap: () => Navigator.pop(context, q),
                    ),
                  if (widget.clearLabel != null && q.isEmpty)
                    ListTile(
                      leading: const Icon(Icons.block),
                      title: Text(widget.clearLabel!),
                      onTap: () => Navigator.pop(context, ''),
                    ),
                  for (final o in hits)
                    ListTile(
                      title: Text(o),
                      trailing: o == widget.current
                          ? Icon(Icons.check, color: theme.colorScheme.primary)
                          : null,
                      onTap: () => Navigator.pop(context, o),
                    ),
                  if (showCustom && hits.isNotEmpty)
                    ListTile(
                      key: const Key('picker-custom'),
                      leading: const Icon(Icons.edit),
                      title: Text('Usar «$q»'),
                      subtitle: hits.isEmpty ? const Text('No está en la lista') : null,
                      onTap: () => Navigator.pop(context, q),
                    ),
                  if (hits.isEmpty && !showCustom)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Sin coincidencias.', textAlign: TextAlign.center),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Read-only field that opens a picker when tapped.
class PickerField extends StatelessWidget {
  const PickerField({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
    this.hint,
    this.helperText,
    this.errorText,
  });

  final String label;
  final String? value;
  final VoidCallback onTap;
  final String? hint;
  final String? helperText;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final empty = value == null || value!.isEmpty;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        isEmpty: empty,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helperText,
          errorText: errorText,
          border: const OutlineInputBorder(),
          suffixIcon: const Icon(Icons.arrow_drop_down),
        ),
        child: Text(empty ? '' : value!, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}
