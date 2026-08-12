import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_radii.dart';
import '../theme/app_typography.dart';
import '../../features/auth/data/signup_options.dart';

/// Picks ONE country from the signup list, with a search field — the list runs
/// past 170 entries, so scrolling to find one is not a real option.
///
/// Returns the chosen name, or null if the sheet was dismissed. The "no
/// country" choice is an explicit first row rather than expecting the user to
/// work out that clearing the field means no targeting.
///
/// [noneLabel]/[noneSubtitle] name that first row. The defaults are the
/// targeting wording ("Everywhere"), which is right when you're saying where
/// something should RUN and wrong when you're saying where you ARE — Settings
/// passes its own.
Future<String?> showCountryPicker(
  BuildContext context, {
  String? current,
  String noneLabel = 'Everywhere',
  String noneSubtitle = 'No country preference',
}) {
  return showModalBottomSheet<String?>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: AppRadii.sheetTop),
    builder: (_) => _CountryPickerSheet(
      current: current,
      noneLabel: noneLabel,
      noneSubtitle: noneSubtitle,
    ),
  );
}

/// Sentinel the sheet pops for "no country" — distinct from a dismiss, which
/// pops null and must leave the existing choice alone.
const String kEverywhere = '__everywhere__';

class _CountryPickerSheet extends StatefulWidget {
  const _CountryPickerSheet({
    this.current,
    required this.noneLabel,
    required this.noneSubtitle,
  });
  final String? current;
  final String noneLabel;
  final String noneSubtitle;

  @override
  State<_CountryPickerSheet> createState() => _CountryPickerSheetState();
}

class _CountryPickerSheetState extends State<_CountryPickerSheet> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<String> get _results {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return kCountries;
    // Names that START with the query first — typing "ken" should put Kenya at
    // the top, not somewhere below every country that merely contains "ken".
    final starts = <String>[];
    final contains = <String>[];
    for (final c in kCountries) {
      final lower = c.toLowerCase();
      if (lower.startsWith(q)) {
        starts.add(c);
      } else if (lower.contains(q)) {
        contains.add(c);
      }
    }
    return [...starts, ...contains];
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return Padding(
      // Sits above the keyboard rather than behind it.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (context, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Choose a country',
                        style: AppTypography.sans(
                            fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.text)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: AppColors.text),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _controller,
                autofocus: true,
                style: AppTypography.sans(fontSize: 16, color: AppColors.text),
                decoration: const InputDecoration(
                  hintText: 'Search countries',
                  prefixIcon: Icon(Icons.search, color: AppColors.muted),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                // +1 for the "Everywhere" row, only when not filtering.
                itemCount: results.length + (_query.trim().isEmpty ? 1 : 0),
                itemBuilder: (context, i) {
                  if (_query.trim().isEmpty && i == 0) {
                    return ListTile(
                      leading: const Icon(Icons.public, color: AppColors.muted),
                      title: Text(widget.noneLabel,
                          style: AppTypography.sans(
                              fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.text)),
                      subtitle: Text(widget.noneSubtitle,
                          style: AppTypography.sans(fontSize: 14, color: AppColors.muted)),
                      trailing: widget.current == null
                          ? const Icon(Icons.check, color: AppColors.accent)
                          : null,
                      onTap: () => Navigator.of(context).pop(kEverywhere),
                    );
                  }
                  final name = results[i - (_query.trim().isEmpty ? 1 : 0)];
                  final selected = name == widget.current;
                  return ListTile(
                    title: Text(name,
                        style: AppTypography.sans(
                          fontSize: 17,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                          color: selected ? AppColors.accent : AppColors.text,
                        )),
                    trailing: selected ? const Icon(Icons.check, color: AppColors.accent) : null,
                    onTap: () => Navigator.of(context).pop(name),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
