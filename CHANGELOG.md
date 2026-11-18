# Changelog

## v0.2.0 - 2026-11-17

- feat: tokenize incrementally from a std.Io.Reader with a bounded buffer (f7d7a8e)
- ci: pin Zig 0.17.0-dev.1857 (47271eb)
- docs: update Discord community links (93784e7)
- docs: add Community section to README (bb9b055)

## 0.1.0

Initial release.

- Lenient, pull-based XML/HTML tokenizer (`Reader`) yielding element
  open/close, text, CDATA, comment, processing-instruction, and declaration
  events, borrowing all names and raw values from the input.
- Quoted, single-quoted, unquoted, and valueless attribute forms.
- Character-reference decoding (`decode` / `decodeInto`) over the HTML5
  named-entity table plus decimal and hex numeric references.
- Unterminated constructs run to end of input without erroring, suiting
  inspection of hostile or malformed markup.
