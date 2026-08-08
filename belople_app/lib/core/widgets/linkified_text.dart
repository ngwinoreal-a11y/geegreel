import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

final _urlRegex = RegExp(r'(https?:\/\/[^\s]+)');

/// The first http(s) URL in a string, or null — used to drive a link preview.
String? firstUrl(String text) => _urlRegex.firstMatch(text)?.group(0);

/// Body text with tappable links and an optional "more/less" expander for
/// long captions (matches the public feed's collapsed-then-expand behaviour).
class LinkifiedText extends StatefulWidget {
  const LinkifiedText({
    super.key,
    required this.text,
    this.style,
    this.collapsedLines = 3,
    this.expandable = true,
  });

  final String text;
  final TextStyle? style;
  final int collapsedLines;
  final bool expandable;

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  bool _expanded = false;

  List<InlineSpan> _spans(TextStyle base) {
    if (!_urlRegex.hasMatch(widget.text)) return [TextSpan(text: widget.text)];
    final spans = <InlineSpan>[];
    var index = 0;
    for (final m in _urlRegex.allMatches(widget.text)) {
      if (m.start > index) spans.add(TextSpan(text: widget.text.substring(index, m.start)));
      final url = m.group(0)!;
      spans.add(TextSpan(
        text: url,
        style: const TextStyle(color: AppColors.verified, decoration: TextDecoration.underline),
        recognizer: TapGestureRecognizer()
          ..onTap = () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      ));
      index = m.end;
    }
    if (index < widget.text.length) spans.add(TextSpan(text: widget.text.substring(index)));
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.style ?? AppTypography.sans(fontSize: 14);
    return LayoutBuilder(
      builder: (context, constraints) {
        final tp = TextPainter(
          text: TextSpan(text: widget.text, style: base),
          maxLines: widget.collapsedLines,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = widget.expandable && tp.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(style: base, children: _spans(base)),
              maxLines: (overflows && !_expanded) ? widget.collapsedLines : null,
              overflow: (overflows && !_expanded) ? TextOverflow.ellipsis : TextOverflow.clip,
            ),
            if (overflows)
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(_expanded ? 'less' : 'more',
                      style: AppTypography.sans(fontSize: 13, color: AppColors.muted, fontWeight: FontWeight.w600)),
                ),
              ),
          ],
        );
      },
    );
  }
}
