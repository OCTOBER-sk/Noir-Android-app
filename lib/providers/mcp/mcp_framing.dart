// lib/providers/mcp/mcp_framing.dart — turning bytes into MCP frames.
//
// Two framings are in play:
//
//   * stdio servers speak newline-delimited JSON (MCP stdio transport);
//   * HTTP servers may answer a POST with `text/event-stream` (MCP Streamable
//     HTTP transport), where each `data:` field is one JSON-RPC message.
//
// Both are pure byte in / frame out, with no protocol knowledge, so a test can
// feed them a chunk that splits a frame down the middle and still get exactly
// one frame out.
import 'dart:convert';

import 'mcp_protocol.dart';

/// Refuses frames larger than this. A server that never sends a newline would
/// otherwise grow the buffer until the app dies.
const int kMcpMaxFrameBytes = 4 * 1024 * 1024;

/// Splits a byte stream into lines, KEEPING empty lines.
///
/// SSE uses a blank line as the event delimiter, so a splitter that quietly
/// dropped empty lines would never end an event. [McpFrameSplitter] is built on
/// this and filters the empties back out.
class McpLineSplitter {
  McpLineSplitter({
    this.maxLineBytes = kMcpMaxFrameBytes,
    this.onFramingFailure,
  });

  final int maxLineBytes;
  final void Function(McpFramingException failure)? onFramingFailure;

  final List<int> _pending = <int>[];

  List<String> addText(String chunk) => addBytes(utf8.encode(chunk));

  List<String> addBytes(List<int> chunk) {
    _pending.addAll(chunk);
    final List<String> lines = <String>[];
    int lineStart = 0;
    for (int index = 0; index < _pending.length; index += 1) {
      if (_pending[index] != 0x0A) continue;
      lines.add(_decodeLine(_pending, lineStart, index));
      lineStart = index + 1;
    }
    if (lineStart > 0) _pending.removeRange(0, lineStart);
    _guard();
    return lines;
  }

  /// Flushes a trailing line that arrived without its newline.
  List<String> close() {
    if (_pending.isEmpty) return const <String>[];
    final String line = _decodeLine(_pending, 0, _pending.length);
    _pending.clear();
    return <String>[line];
  }

  void _guard() {
    if (_pending.length <= maxLineBytes) return;
    _pending.clear();
    onFramingFailure?.call(
      const McpFramingException(
        kMcpFrameTooLarge,
        'MCP line exceeded the maximum frame size and was dropped',
      ),
    );
  }

  static String _decodeLine(List<int> bytes, int start, int end) {
    int last = end;
    if (last > start && bytes[last - 1] == 0x0D) last -= 1; // CRLF
    if (last <= start) return '';
    return utf8.decode(bytes.sublist(start, last), allowMalformed: true);
  }
}

/// Splits a byte stream into newline-delimited frames, dropping blank lines.
class McpFrameSplitter {
  McpFrameSplitter({
    this.maxFrameBytes = kMcpMaxFrameBytes,
    this.onFramingFailure,
  }) : _lines = McpLineSplitter(
         maxLineBytes: maxFrameBytes,
         onFramingFailure: onFramingFailure,
       );

  final int maxFrameBytes;
  final void Function(McpFramingException failure)? onFramingFailure;
  final McpLineSplitter _lines;

  List<String> addText(String chunk) => _frames(_lines.addText(chunk));

  List<String> addBytes(List<int> chunk) => _frames(_lines.addBytes(chunk));

  /// Flushes a trailing frame that arrived without its newline.
  List<String> close() => _frames(_lines.close());

  static List<String> _frames(List<String> lines) => <String>[
    for (final String line in lines)
      if (line.trim().isNotEmpty) line,
  ];
}

/// Splits a `text/event-stream` body into MCP frames.
///
/// A blank line ends an event, `:` starts a comment (SSE keep-alive, which must
/// never be mistaken for a frame), and multi-line `data:` fields are joined
/// with newlines exactly as the SSE specification requires.
class McpSseDecoder {
  final List<String> _data = <String>[];

  List<String> addLine(String line) {
    if (line.isEmpty) return _flush();
    if (line.startsWith(':')) return const <String>[];
    final int colon = line.indexOf(':');
    if (colon < 0) return const <String>[];
    if (line.substring(0, colon) != 'data') return const <String>[];
    String value = line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    _data.add(value);
    return const <String>[];
  }

  /// Flushes an event that the server ended without a trailing blank line.
  List<String> close() => _flush();

  List<String> _flush() {
    if (_data.isEmpty) return const <String>[];
    final String frame = _data.join('\n');
    _data.clear();
    return <String>[frame];
  }
}
