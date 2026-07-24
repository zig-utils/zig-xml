//! A small, lenient, pull-based XML/HTML tokenizer.
//!
//! `Reader` walks a byte slice and yields structural events — element open/close,
//! text, CDATA, comments, processing instructions, and declarations — borrowing
//! every name and raw value from the input. It performs no entity decoding and
//! no allocation per event; attribute storage is a single reused list, and the
//! `entity` module provides on-demand character-reference decoding.
//!
//! Leniency is deliberate: this is meant to inspect hostile or malformed markup
//! (WAF request bodies, scrapers) the way browsers and Go's non-strict
//! `encoding/xml` do, not to validate well-formedness. Unterminated constructs
//! end the stream rather than error, mismatched close tags are reported as-is,
//! and unquoted or valueless attributes are accepted.

const std = @import("std");

pub const entity = @import("entity.zig");

pub const Error = std.mem.Allocator.Error;

pub const Attribute = struct {
    name: []const u8,
    /// The raw (still entity-encoded) attribute value; quotes stripped.
    value: []const u8,
};

pub const Element = struct {
    name: []const u8,
    /// Borrowed from the reader's attribute list; valid only until the next
    /// call to `Reader.next`.
    attributes: []const Attribute,

    pub fn attribute(self: Element, name: []const u8) ?[]const u8 {
        for (self.attributes) |attr| {
            if (std.mem.eql(u8, attr.name, name)) return attr.value;
        }
        return null;
    }
};

pub const Event = union(enum) {
    /// `<tag ...>`
    open: Element,
    /// `<tag .../>`
    self_closing: Element,
    /// `</tag>`
    close: []const u8,
    /// Raw (entity-encoded) character data between tags.
    text: []const u8,
    /// `<![CDATA[ ... ]]>` — raw, never entity-decoded.
    cdata: []const u8,
    /// `<!-- ... -->` inner text.
    comment: []const u8,
    /// `<? ... ?>` inner text (target and data).
    processing_instruction: []const u8,
    /// `<!DOCTYPE ...>` / other `<! ... >` declarations, inner text.
    declaration: []const u8,
};

pub const Reader = struct {
    input: []const u8,
    pos: usize = 0,
    attributes: std.ArrayList(Attribute) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Reader {
        return .{ .input = input, .allocator = allocator };
    }

    pub fn deinit(self: *Reader) void {
        self.attributes.deinit(self.allocator);
        self.* = undefined;
    }

    fn rest(self: *const Reader) []const u8 {
        return self.input[self.pos..];
    }

    fn startsWith(self: *const Reader, needle: []const u8) bool {
        return std.mem.startsWith(u8, self.rest(), needle);
    }

    /// Find `needle` at or after the cursor; returns the end of input if absent
    /// (lenient: an unterminated construct runs to EOF).
    fn indexOfOrEnd(self: *const Reader, needle: []const u8) usize {
        return std.mem.indexOfPos(u8, self.input, self.pos, needle) orelse self.input.len;
    }

    pub fn next(self: *Reader) Error!?Event {
        if (self.pos >= self.input.len) return null;

        if (self.input[self.pos] != '<') {
            // Character data up to the next tag.
            const start = self.pos;
            const lt = std.mem.indexOfScalarPos(u8, self.input, self.pos, '<') orelse self.input.len;
            self.pos = lt;
            return .{ .text = self.input[start..lt] };
        }

        // A markup construct begins at '<'.
        if (self.startsWith("<!--")) {
            self.pos += "<!--".len;
            const start = self.pos;
            const end = self.indexOfOrEnd("-->");
            const inner = self.input[start..end];
            self.pos = if (end < self.input.len) end + "-->".len else end;
            return .{ .comment = inner };
        }
        if (self.startsWith("<![CDATA[")) {
            self.pos += "<![CDATA[".len;
            const start = self.pos;
            const end = self.indexOfOrEnd("]]>");
            const inner = self.input[start..end];
            self.pos = if (end < self.input.len) end + "]]>".len else end;
            return .{ .cdata = inner };
        }
        if (self.startsWith("<!")) {
            self.pos += "<!".len;
            const start = self.pos;
            const end = self.indexOfOrEnd(">");
            const inner = self.input[start..end];
            self.pos = if (end < self.input.len) end + 1 else end;
            return .{ .declaration = inner };
        }
        if (self.startsWith("<?")) {
            self.pos += "<?".len;
            const start = self.pos;
            // Prefer "?>" but tolerate a bare ">".
            const q = std.mem.indexOfPos(u8, self.input, self.pos, "?>");
            const end = q orelse self.indexOfOrEnd(">");
            const inner = self.input[start..end];
            self.pos = if (q != null) end + "?>".len else (if (end < self.input.len) end + 1 else end);
            return .{ .processing_instruction = inner };
        }
        if (self.startsWith("</")) {
            self.pos += "</".len;
            const name = self.readName();
            // Skip to the closing '>'.
            const end = self.indexOfOrEnd(">");
            self.pos = if (end < self.input.len) end + 1 else end;
            return .{ .close = name };
        }

        // A start tag: '<' name attributes ('>' | '/>').
        self.pos += 1; // consume '<'
        const name = self.readName();
        if (name.len == 0) {
            // A stray '<' that is not a tag; treat the '<' as text so we make
            // progress instead of looping.
            return .{ .text = self.input[self.pos - 1 .. self.pos] };
        }
        self.attributes.clearRetainingCapacity();
        var self_closing = false;
        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.pos >= self.input.len) break;
            const c = self.input[self.pos];
            if (c == '>') {
                self.pos += 1;
                break;
            }
            if (c == '/') {
                self.pos += 1;
                self.skipWhitespace();
                if (self.pos < self.input.len and self.input[self.pos] == '>') self.pos += 1;
                self_closing = true;
                break;
            }
            // An attribute: name [ '=' value ].
            const attr_name = self.readName();
            if (attr_name.len == 0) {
                // Not a valid attribute char; skip one byte to avoid stalling.
                self.pos += 1;
                continue;
            }
            self.skipWhitespace();
            var value: []const u8 = "";
            if (self.pos < self.input.len and self.input[self.pos] == '=') {
                self.pos += 1;
                self.skipWhitespace();
                value = self.readAttributeValue();
            }
            try self.attributes.append(self.allocator, .{ .name = attr_name, .value = value });
        }

        const element: Element = .{ .name = name, .attributes = self.attributes.items };
        return if (self_closing) .{ .self_closing = element } else .{ .open = element };
    }

    fn skipWhitespace(self: *Reader) void {
        while (self.pos < self.input.len and isSpace(self.input[self.pos])) self.pos += 1;
    }

    /// Read an element or attribute name: everything up to whitespace or one of
    /// the tag-structural characters.
    fn readName(self: *Reader) []const u8 {
        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (isSpace(c) or c == '>' or c == '/' or c == '=' or c == '<') break;
            self.pos += 1;
        }
        return self.input[start..self.pos];
    }

    fn readAttributeValue(self: *Reader) []const u8 {
        if (self.pos >= self.input.len) return "";
        const quote = self.input[self.pos];
        if (quote == '"' or quote == '\'') {
            self.pos += 1;
            const start = self.pos;
            const end = std.mem.indexOfScalarPos(u8, self.input, self.pos, quote) orelse self.input.len;
            self.pos = if (end < self.input.len) end + 1 else end;
            return self.input[start..end];
        }
        // Unquoted value: up to whitespace, '>' or '/'.
        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (isSpace(c) or c == '>' or c == '/') break;
            self.pos += 1;
        }
        return self.input[start..self.pos];
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

// ---- entity decoding ----------------------------------------------------

/// Decode XML/HTML character references in `raw` into `out`. Named references
/// resolve through the HTML5 table (`entity.lookup`); `&#NN;` and `&#xNN;`
/// decode numeric code points. Anything unrecognized is emitted verbatim, which
/// is the lenient behavior a WAF wants — no reference is silently dropped.
pub fn decodeInto(out: *std.ArrayList(u8), allocator: std.mem.Allocator, raw: []const u8) Error!void {
    var i: usize = 0;
    while (i < raw.len) {
        const amp = std.mem.indexOfScalarPos(u8, raw, i, '&') orelse {
            try out.appendSlice(allocator, raw[i..]);
            break;
        };
        try out.appendSlice(allocator, raw[i..amp]);
        // Find the terminating ';' within a bounded window (entity names are
        // short; an unterminated '&' is literal text).
        const semi = std.mem.indexOfScalarPos(u8, raw, amp, ';') orelse {
            try out.append(allocator, '&');
            i = amp + 1;
            continue;
        };
        const token = raw[amp .. semi + 1]; // includes '&' and ';'
        if (decodeReference(token)) |codepoints| {
            for (codepoints) |cp| {
                if (cp == 0) continue;
                var buffer: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buffer) catch {
                    // An out-of-range code point: keep the raw token.
                    try out.appendSlice(allocator, token);
                    break;
                };
                try out.appendSlice(allocator, buffer[0..len]);
            }
            i = semi + 1;
        } else {
            // Unknown reference — emit the '&' and continue after it so a later
            // valid reference in the same run still resolves.
            try out.append(allocator, '&');
            i = amp + 1;
        }
    }
}

/// Convenience wrapper returning an owned decoded copy.
pub fn decode(allocator: std.mem.Allocator, raw: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try decodeInto(&out, allocator, raw);
    return out.toOwnedSlice(allocator);
}

/// Resolve a single `&...;` token (including the ampersand and semicolon).
fn decodeReference(token: []const u8) ?[2]u21 {
    if (token.len < 3) return null; // "&;" and shorter cannot resolve
    if (token[1] == '#') {
        const digits = token[2 .. token.len - 1];
        if (digits.len == 0) return null;
        const cp: u21 = blk: {
            if (digits[0] == 'x' or digits[0] == 'X') {
                break :blk std.fmt.parseInt(u21, digits[1..], 16) catch return null;
            }
            break :blk std.fmt.parseInt(u21, digits, 10) catch return null;
        };
        if (cp == 0 or cp > 0x10FFFF) return null;
        return .{ cp, 0 };
    }
    return entity.lookup(token);
}

// ---- tests --------------------------------------------------------------

fn collect(allocator: std.mem.Allocator, input: []const u8) ![]Event {
    var reader = Reader.init(allocator, input);
    defer reader.deinit();
    var events: std.ArrayList(Event) = .empty;
    // Attribute slices are only valid until the next `next()`, so copy any we
    // need to retain. For these tests we assert immediately per event instead.
    while (try reader.next()) |event| try events.append(allocator, event);
    return events.toOwnedSlice(allocator);
}

test "a simple element yields open, text, and close" {
    var reader = Reader.init(std.testing.allocator, "<a>hello</a>");
    defer reader.deinit();
    try std.testing.expectEqualStrings("a", (try reader.next()).?.open.name);
    try std.testing.expectEqualStrings("hello", (try reader.next()).?.text);
    try std.testing.expectEqualStrings("a", (try reader.next()).?.close);
    try std.testing.expect((try reader.next()) == null);
}

test "attributes parse in quoted, single-quoted, unquoted, and valueless forms" {
    var reader = Reader.init(std.testing.allocator, "<x a=\"1\" b='2' c=3 d>");
    defer reader.deinit();
    const element = (try reader.next()).?.open;
    try std.testing.expectEqual(@as(usize, 4), element.attributes.len);
    try std.testing.expectEqualStrings("1", element.attribute("a").?);
    try std.testing.expectEqualStrings("2", element.attribute("b").?);
    try std.testing.expectEqualStrings("3", element.attribute("c").?);
    try std.testing.expectEqualStrings("", element.attribute("d").?);
}

test "self-closing tags are distinguished from open tags" {
    var reader = Reader.init(std.testing.allocator, "<br/><img src=\"x\" />");
    defer reader.deinit();
    try std.testing.expectEqualStrings("br", (try reader.next()).?.self_closing.name);
    const img = (try reader.next()).?.self_closing;
    try std.testing.expectEqualStrings("img", img.name);
    try std.testing.expectEqualStrings("x", img.attribute("src").?);
}

test "comments, CDATA, PIs, and declarations are recognized" {
    const events = try collect(std.testing.allocator, "<!--c--><![CDATA[<raw>]]><?pi go?><!DOCTYPE html>");
    defer std.testing.allocator.free(events);
    try std.testing.expectEqualStrings("c", events[0].comment);
    try std.testing.expectEqualStrings("<raw>", events[1].cdata);
    try std.testing.expectEqualStrings("pi go", events[2].processing_instruction);
    try std.testing.expectEqualStrings("DOCTYPE html", events[3].declaration);
}

test "unterminated constructs run to end of input without erroring" {
    var reader = Reader.init(std.testing.allocator, "<a><!-- never closed");
    defer reader.deinit();
    try std.testing.expectEqualStrings("a", (try reader.next()).?.open.name);
    try std.testing.expectEqualStrings(" never closed", (try reader.next()).?.comment);
    try std.testing.expect((try reader.next()) == null);
}

test "named, decimal, and hex references decode; unknown stays literal" {
    const cases = [_]struct { raw: []const u8, want: []const u8 }{
        .{ .raw = "a &amp; b", .want = "a & b" },
        .{ .raw = "&lt;tag&gt;", .want = "<tag>" },
        .{ .raw = "&#60;&#x3e;", .want = "<>" },
        .{ .raw = "&#x41;&#x42;", .want = "AB" },
        .{ .raw = "&unknownentity; stays", .want = "&unknownentity; stays" },
        .{ .raw = "bare & ampersand", .want = "bare & ampersand" },
        .{ .raw = "trailing &", .want = "trailing &" },
    };
    for (cases) |case| {
        const decoded = try decode(std.testing.allocator, case.raw);
        defer std.testing.allocator.free(decoded);
        try std.testing.expectEqualStrings(case.want, decoded);
    }
}

test "attribute values are decoded on demand" {
    var reader = Reader.init(std.testing.allocator, "<a href=\"?x=1&amp;y=2\">");
    defer reader.deinit();
    const element = (try reader.next()).?.open;
    const decoded = try decode(std.testing.allocator, element.attribute("href").?);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("?x=1&y=2", decoded);
}

test "nested elements and mixed content walk in order" {
    var reader = Reader.init(std.testing.allocator, "<r><a x=\"1\">t1</a><b/>t2</r>");
    defer reader.deinit();
    try std.testing.expectEqualStrings("r", (try reader.next()).?.open.name);
    try std.testing.expectEqualStrings("a", (try reader.next()).?.open.name);
    try std.testing.expectEqualStrings("t1", (try reader.next()).?.text);
    try std.testing.expectEqualStrings("a", (try reader.next()).?.close);
    try std.testing.expectEqualStrings("b", (try reader.next()).?.self_closing.name);
    try std.testing.expectEqualStrings("t2", (try reader.next()).?.text);
    try std.testing.expectEqualStrings("r", (try reader.next()).?.close);
    try std.testing.expect((try reader.next()) == null);
}

test "a stray less-than is emitted as text rather than looping" {
    var reader = Reader.init(std.testing.allocator, "a < b");
    defer reader.deinit();
    try std.testing.expectEqualStrings("a ", (try reader.next()).?.text);
    // "< b" — '<' followed by a space is not a name; emit '<' as text.
    try std.testing.expectEqualStrings("<", (try reader.next()).?.text);
    try std.testing.expectEqualStrings(" b", (try reader.next()).?.text);
    try std.testing.expect((try reader.next()) == null);
}

test "random bytes never crash or stall the tokenizer" {
    var prng = std.Random.DefaultPrng.init(0xA11CE_5EED);
    const random = prng.random();
    var buffer: [256]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 5000) : (iteration += 1) {
        const len = random.uintLessThan(usize, buffer.len + 1);
        for (buffer[0..len]) |*byte| {
            byte.* = switch (random.uintLessThan(u8, 10)) {
                0 => '<',
                1 => '>',
                2 => '/',
                3 => '=',
                4 => '"',
                5 => '&',
                6 => ';',
                7 => ' ',
                else => random.int(u8),
            };
        }
        var reader = Reader.init(std.testing.allocator, buffer[0..len]);
        defer reader.deinit();
        var guard: usize = 0;
        while (try reader.next()) |_| {
            guard += 1;
            if (guard > len + 2) return error.NonTerminating;
        }
    }
}
