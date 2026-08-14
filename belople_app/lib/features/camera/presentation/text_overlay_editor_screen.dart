import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../data/video_text_overlay.dart';

/// Text onto the clip: type it, drag it anywhere, pick a colour and a size.
///
/// A screen of its own rather than a layer on the composer, and not for looks.
/// The composer's step 2 is a [SingleChildScrollView]; a drag started on a
/// preview inside one is claimed by the scrollable long before a pan
/// recogniser in the child gets it, so dragging text up the frame would scroll
/// the page instead. Full screen, nothing scrolling behind it, and the drag is
/// unambiguous.
///
/// Returns the edited list, or null when the poster backed out — the caller
/// keeps what it had.
class TextOverlayEditorScreen extends StatefulWidget {
  const TextOverlayEditorScreen({
    super.key,
    required this.videoPath,
    required this.overlays,
    this.tint,
  });

  final String videoPath;
  final List<VideoTextOverlay> overlays;

  /// The look riding on the clip, so text is placed over the graded picture
  /// rather than the raw one — the same [ColorFilter] the composer preview and
  /// the FFmpeg pass both use.
  final ColorFilter? tint;

  @override
  State<TextOverlayEditorScreen> createState() => _TextOverlayEditorScreenState();
}

class _TextOverlayEditorScreenState extends State<TextOverlayEditorScreen> {
  late final List<VideoTextOverlay> _items =
      widget.overlays.map((o) => o.copyWith()).toList();

  VideoPlayerController? _controller;

  /// The overlay currently being typed into, or null when nothing is.
  VideoTextOverlay? _editing;
  final _textController = TextEditingController();
  final _focus = FocusNode();

  /// True while [_editing] was created by this screen and has never held any
  /// text — backing out of it removes it instead of leaving an empty overlay
  /// nobody can see or select.
  bool _editingIsNew = false;

  @override
  void initState() {
    super.initState();
    _openVideo();
  }

  /// Its own controller, muted and looping. The composer's controller is still
  /// alive on the screen underneath and taking it over would leave that screen
  /// with a dead player when this one pops.
  Future<void> _openVideo() async {
    final c = VideoPlayerController.file(File(widget.videoPath));
    try {
      await c.initialize();
      await c.setLooping(true);
      await c.setVolume(0);
      await c.play();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
    } catch (e) {
      // Placing text over a black rectangle is placing it blind, so this one
      // does have to reach the person, not just the log.
      debugPrint('[BLTEXT] could not open ${widget.videoPath} for the text editor: $e');
      await c.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't open the clip to put text on it")),
        );
        Navigator.of(context).pop();
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _textController.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _add() {
    final overlay = VideoTextOverlay(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      dx: 0.5,
      dy: 0.5,
    );
    setState(() {
      _items.add(overlay);
      _editingIsNew = true;
    });
    _beginEditing(overlay);
  }

  void _beginEditing(VideoTextOverlay overlay) {
    _textController.text = overlay.text;
    _textController.selection = TextSelection.collapsed(offset: overlay.text.length);
    setState(() => _editing = overlay);
    // The keyboard has to be asked for after the field exists.
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  /// Leaves typing mode. An overlay with nothing in it is dropped: there is no
  /// way to select or delete something that paints no pixels.
  void _endEditing() {
    final editing = _editing;
    if (editing == null) return;
    setState(() {
      editing.text = _textController.text;
      if (editing.isEmpty) _items.remove(editing);
      _editing = null;
      _editingIsNew = false;
    });
    _focus.unfocus();
  }

  void _deleteEditing() {
    final editing = _editing;
    if (editing == null) return;
    setState(() {
      _items.remove(editing);
      _editing = null;
      _editingIsNew = false;
    });
    _focus.unfocus();
  }

  /// Moves [overlay] by a finger's delta, in the frame's own coordinates.
  ///
  /// The delta is divided by the FREE space rather than the frame, because that
  /// is what dx/dy measure — dividing by the frame instead makes a long line
  /// travel further than the finger and stop short of the edge.
  void _drag(VideoTextOverlay overlay, Offset delta, Size frame) {
    final block = overlayPainter(overlay, frame.width).size;
    final freeW = (frame.width - block.width).clamp(1.0, double.infinity);
    final freeH = (frame.height - block.height).clamp(1.0, double.infinity);
    setState(() {
      overlay.dx = (overlay.dx + delta.dx / freeW).clamp(0.0, 1.0);
      overlay.dy = (overlay.dy + delta.dy / freeH).clamp(0.0, 1.0);
    });
  }

  void _done() {
    if (_editing != null) _endEditing();
    Navigator.of(context).pop(_items.where((o) => !o.isEmpty).toList());
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final typing = _editing != null;

    return PopScope(
      // Back while typing closes the keyboard and keeps the screen, the way
      // every text tool behaves. Only a second back leaves.
      canPop: !typing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (_editingIsNew) {
            _deleteEditing();
          } else {
            _endEditing();
          }
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          child: Stack(
            children: [
              Center(
                child: controller == null || !controller.value.isInitialized
                    ? const CircularProgressIndicator(color: AppColors.accent)
                    : AspectRatio(
                        aspectRatio: controller.value.aspectRatio,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final frame =
                                Size(constraints.maxWidth, constraints.maxHeight);
                            return Stack(
                              children: [
                                Positioned.fill(
                                  child: widget.tint == null
                                      ? VideoPlayer(controller)
                                      : ColorFiltered(
                                          colorFilter: widget.tint!,
                                          child: VideoPlayer(controller),
                                        ),
                                ),
                                for (final overlay in _items)
                                  if (overlay != _editing)
                                    _DraggableText(
                                      overlay: overlay,
                                      frame: frame,
                                      onDrag: (d) => _drag(overlay, d, frame),
                                      onTap: () => _beginEditing(overlay),
                                    ),
                              ],
                            );
                          },
                        ),
                      ),
              ),

              // Typing: a scrim over the clip, the field where the text will
              // sit, and the two controls that shape it.
              if (typing) _buildTypingLayer(),

              _buildTopBar(typing),
              if (!typing) _buildAddButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(bool typing) => Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (typing)
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.white, size: 26),
                tooltip: 'Delete this text',
                onPressed: _deleteEditing,
              )
            else
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 26),
                tooltip: 'Discard',
                onPressed: () => Navigator.of(context).pop(),
              ),
            TextButton(
              onPressed: typing ? _endEditing : _done,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.accent,
                textStyle: AppTypography.sans(fontSize: 18, fontWeight: FontWeight.w800),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              child: Text(typing ? 'Done' : 'Save'),
            ),
          ],
        ),
      );

  Widget _buildAddButton() => Positioned(
        left: 0,
        right: 0,
        bottom: 24,
        child: Center(
          // Intrinsic width, not the theme's. ElevatedButton inherits a
          // full-width minimum from the app theme, which painted an amber slab
          // right across the bottom of the clip being edited — over the very
          // picture the text is being placed on.
          child: IntrinsicWidth(
            child: ElevatedButton.icon(
              onPressed: _add,
              icon: const Text('Aa',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, height: 1)),
              label: Text(_items.isEmpty ? 'Add text' : 'Add more'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.black,
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                textStyle: AppTypography.sans(fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ),
      );

  Widget _buildTypingLayer() {
    final editing = _editing!;
    return Positioned.fill(
      child: GestureDetector(
        // Tapping the dark area finishes, the way a caption sheet does.
        onTap: _endEditing,
        child: Container(
          color: Colors.black.withValues(alpha: 0.55),
          child: Column(
            children: [
              const SizedBox(height: 56),
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: LayoutBuilder(
                      builder: (context, constraints) => TextField(
                        controller: _textController,
                        focusNode: _focus,
                        autofocus: true,
                        maxLines: kOverlayMaxLines,
                        minLines: 1,
                        textAlign: TextAlign.center,
                        cursorColor: AppColors.accent,
                        // The field is drawn in the very style the frame will
                        // carry, so the size slider and the colours are judged
                        // against the real thing and not a stand-in.
                        style: overlayTextStyle(editing, constraints.maxWidth),
                        onChanged: (v) => setState(() => editing.text = v),
                        decoration: const InputDecoration(
                          // The app's global InputDecorationTheme fills fields
                          // with dark chrome — over a video that paints a slab
                          // across the picture being typed on.
                          filled: false,
                          border: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          hintText: 'Type something',
                          hintStyle: TextStyle(color: Colors.white54),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              _buildSizeSlider(editing),
              _buildColorStrip(editing),
              // Clears the keyboard, so the controls above it are reachable
              // with a thumb rather than hidden behind it.
              SizedBox(height: MediaQuery.of(context).viewInsets.bottom),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSizeSlider(VideoTextOverlay editing) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(
          children: [
            const Text('A', style: TextStyle(color: Colors.white70, fontSize: 13)),
            Expanded(
              child: Slider(
                value: editing.scale.clamp(kOverlayMinScale, kOverlayMaxScale),
                min: kOverlayMinScale,
                max: kOverlayMaxScale,
                activeColor: AppColors.accent,
                inactiveColor: Colors.white24,
                onChanged: (v) => setState(() => editing.scale = v),
              ),
            ),
            const Text('A', style: TextStyle(color: Colors.white70, fontSize: 24)),
          ],
        ),
      );

  Widget _buildColorStrip(VideoTextOverlay editing) => SizedBox(
        height: 62,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          itemCount: kOverlayTextColors.length,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (context, i) {
            final selected = editing.colorIndex == i;
            return Center(
              child: GestureDetector(
                onTap: () => setState(() => editing.colorIndex = i),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: kOverlayTextColors[i],
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? AppColors.accent : Colors.white54,
                      width: selected ? 3 : 1,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
}

/// One overlay on the frame: shrink-wrapped to its longest line so the thing
/// you drag is the thing you see, and placed by [overlayTopLeft] — the same
/// rule the burnt-in PNG uses.
class _DraggableText extends StatelessWidget {
  const _DraggableText({
    required this.overlay,
    required this.frame,
    required this.onDrag,
    required this.onTap,
  });

  final VideoTextOverlay overlay;
  final Size frame;
  final void Function(Offset delta) onDrag;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final block = overlayPainter(overlay, frame.width).size;
    final topLeft = overlayTopLeft(overlay, frame, block);
    return Positioned(
      left: topLeft.dx,
      top: topLeft.dy,
      width: block.width,
      height: block.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onPanUpdate: (d) => onDrag(d.delta),
        child: Text(
          overlay.text,
          textAlign: TextAlign.center,
          maxLines: kOverlayMaxLines,
          overflow: TextOverflow.ellipsis,
          style: overlayTextStyle(overlay, frame.width),
        ),
      ),
    );
  }
}
