# zig-xml

A small, lenient, allocation-light **XML/HTML tokenizer** for Zig, with HTML5
character-reference decoding.

It is a *pull* tokenizer: you call `next()` and get one structural event at a
time — element open/close, text, CDATA, comments, processing instructions, and
declarations — with every name and raw value **borrowed from the input**. There
is no allocation per event (attribute storage is a single reused list), and no
implicit entity decoding; decoding is a separate, explicit step.

Leniency is deliberate. zig-xml is built to inspect untrusted, possibly
malformed markup (WAF request bodies, scrapers, editor tooling) the way
browsers and Go's non-strict `encoding/xml` do — not to validate
well-formedness. Unterminated constructs run to end of input instead of
erroring, mismatched close tags are reported verbatim, and unquoted or
valueless attributes are accepted. It performs no DTD processing and no external
entity resolution, so it is not exposed to XXE or entity-expansion attacks.

## Install

With [Pantry](https://github.com/home-lang/pantry):

```sh
pantry add zig-xml
```

Then add the module in `build.zig`:

```zig
const xml = b.dependency("xml", .{ .target = target, .optimize = optimize });
your_module.addImport("xml", xml.module("xml"));
```

## Usage

```zig
const std = @import("std");
const xml = @import("xml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var reader = xml.Reader.init(allocator, "<a href=\"?x=1&amp;y=2\">hello</a>");
    defer reader.deinit();

    while (try reader.next()) |event| switch (event) {
        .open, .self_closing => |element| {
            std.debug.print("<{s}>\n", .{element.name});
            for (element.attributes) |attr| {
                // Attribute values are raw; decode when you need the text.
                const value = try xml.decode(allocator, attr.value);
                defer allocator.free(value);
                std.debug.print("  {s} = {s}\n", .{ attr.name, value });
            }
        },
        .text => |raw| {
            const text = try xml.decode(allocator, raw);
            defer allocator.free(text);
            std.debug.print("text: {s}\n", .{text});
        },
        .close => |name| std.debug.print("</{s}>\n", .{name}),
        else => {},
    };
}
```

Attribute slices (and the `Element.attributes` list) are valid only until the
next call to `next()` — copy anything you need to retain.

## API

- `Reader.init(allocator, input) Reader` / `reader.deinit()`
- `reader.next() !?Event`
- `Event` — `open` / `self_closing` (`Element`), `close` (name), `text`,
  `cdata`, `comment`, `processing_instruction`, `declaration`
- `Element{ name, attributes }`, with `element.attribute(name) ?[]const u8`
- `decode(allocator, raw) ![]u8` / `decodeInto(&list, allocator, raw) !void`
- `entity.lookup(name) ?[2]u21` — the underlying HTML5 named-entity table

## License

MIT. The bundled HTML5 named-entity table is vendored from Bun (MIT) — see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
