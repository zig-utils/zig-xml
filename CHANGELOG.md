# Changelog

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
