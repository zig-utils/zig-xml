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

pub const Error = std.mem.Allocator.Error || error{
    /// The stream source failed (`Reader.initStream` only).
    ReadFailed,
    /// A start or end tag is longer than the stream buffer (`Reader.initStream` only).
    TokenTooLong,
};

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
    /// The bytes the tokenizer can see: the whole document for `init`, the
    /// buffered window for `initStream`.
    input: []const u8,
    /// Cursor into `input`.
    pos: usize = 0,
    attributes: std.ArrayList(Attribute) = .empty,
    allocator: std.mem.Allocator,
    /// Set for a reader created with `initStream`.
    stream: ?Stream = null,

    const Stream = struct {
        source: *std.Io.Reader,
        /// Owned window storage; `input` is always a prefix of it.
        buffer: []u8,
        /// The source has reported end of stream.
        eof: bool = false,
        /// Document offset of `input[0]`.
        base: u64 = 0,
        /// A comment, CDATA section, declaration or PI longer than the buffer is
        /// emitted in pieces; this is the kind still being continued.
        pending: ?Continuation = null,
    };

    const Continuation = enum {
        comment,
        cdata,
        declaration,
        processing_instruction,

        fn terminator(self: Continuation) []const u8 {
            return switch (self) {
                .comment => "-->",
                .cdata => "]]>",
                .declaration => ">",
                .processing_instruction => "?>",
            };
        }

        fn event(self: Continuation, inner: []const u8) Event {
            return switch (self) {
                .comment => .{ .comment = inner },
                .cdata => .{ .cdata = inner },
                .declaration => .{ .declaration = inner },
                .processing_instruction => .{ .processing_instruction = inner },
            };
        }
    };

    pub const StreamOptions = struct {
        /// Size of the window the tokenizer reads into: the memory bound, and
        /// the longest token that is guaranteed to come out whole. Values below
        /// `min_buffer_size` are raised to it.
        buffer_size: usize = 64 * 1024,
    };

    pub const min_buffer_size = 64;

    /// Tokenize a document held in memory. Events borrow from `input` and stay
    /// valid as long as it does (attribute lists until the next `next`).
    pub fn init(allocator: std.mem.Allocator, input: []const u8) Reader {
        return .{ .input = input, .allocator = allocator };
    }

    /// Tokenize a document read incrementally from `source`, holding at most
    /// `options.buffer_size` bytes of it. Every slice in an event is valid only
    /// until the next call to `next`.
    ///
    /// For tokens that fit in the buffer the events are the same as `init`
    /// gives for the whole document. Longer tokens differ: text, comments, CDATA,
    /// declarations and processing instructions come out as several consecutive
    /// events of the same kind (a processing instruction then ends only at
    /// `?>`), and a start or end tag longer than the buffer is
    /// `error.TokenTooLong`.
    pub fn initStream(allocator: std.mem.Allocator, source: *std.Io.Reader, options: StreamOptions) Error!Reader {
        const buffer = try allocator.alloc(u8, @max(options.buffer_size, min_buffer_size));
        return .{
            .input = buffer[0..0],
            .allocator = allocator,
            .stream = .{ .source = source, .buffer = buffer },
        };
    }

    pub fn deinit(self: *Reader) void {
        self.attributes.deinit(self.allocator);
        if (self.stream) |s| self.allocator.free(s.buffer);
        self.* = undefined;
    }

    /// Document offset of the next unread byte.
    pub fn offset(self: *const Reader) u64 {
        const base = if (self.stream) |s| s.base else 0;
        return base + self.pos;
    }

    pub fn next(self: *Reader) Error!?Event {
        if (self.stream) |*s| if (s.pending) |kind| return try self.continuePiece(kind);
        while (true) {
            if (self.pos >= self.input.len) {
                if (try self.fillMore()) continue;
                return null;
            }
            const start = self.pos;
            if (self.token()) |event| {
                return event;
            } else |err| switch (err) {
                error.NeedMore => {},
                else => |e| return e,
            }
            // The token runs past the window: rewind and read more.
            self.pos = start;
            if (try self.fillMore()) continue;
            return try self.oversized();
        }
    }

    /// Whether the window holds the rest of the document.
    fn atEof(self: *const Reader) bool {
        const s = self.stream orelse return true;
        return s.eof;
    }

    /// Whether index `i` is the end of the document. `error.NeedMore` when it is
    /// only the end of the window.
    fn endAt(self: *const Reader, i: usize) error{NeedMore}!bool {
        if (i < self.input.len) return false;
        if (self.atEof()) return true;
        return error.NeedMore;
    }

    /// Read more of the source into the window. Returns false when nothing can
    /// change: the source is exhausted or the window is full of one token.
    fn fillMore(self: *Reader) error{ReadFailed}!bool {
        const s = if (self.stream) |*s| s else return false;
        if (s.eof) return false;
        // Drop consumed bytes; only the unfinished token stays.
        if (self.pos > 0) {
            const keep = self.input.len - self.pos;
            std.mem.copyForwards(u8, s.buffer[0..keep], self.input[self.pos..]);
            s.base += self.pos;
            self.pos = 0;
            self.input = s.buffer[0..keep];
        }
        const len = self.input.len;
        if (len == s.buffer.len) return false;
        var data: [1][]u8 = .{s.buffer[len..]};
        while (true) {
            // Zero means the source filled its own buffer; the next call copies it.
            const n = s.source.readVec(&data) catch |err| switch (err) {
                error.EndOfStream => {
                    s.eof = true;
                    return true;
                },
                error.ReadFailed => return error.ReadFailed,
            };
            if (n == 0) continue;
            self.input = s.buffer[0 .. len + n];
            return true;
        }
    }

    /// The token at the cursor does not fit in a full window.
    fn oversized(self: *Reader) Error!Event {
        if (self.input[self.pos] != '<') {
            const text = self.input[self.pos..];
            self.pos = self.input.len;
            return .{ .text = text };
        }
        const prefixes = [_]struct { []const u8, Continuation }{
            .{ "<!--", .comment },
            .{ "<![CDATA[", .cdata },
            .{ "<!", .declaration },
            .{ "<?", .processing_instruction },
        };
        for (prefixes) |entry| {
            const prefix, const kind = entry;
            if (std.mem.startsWith(u8, self.input[self.pos..], prefix)) {
                self.pos += prefix.len;
                return self.piece(kind);
            }
        }
        return error.TokenTooLong;
    }

    /// Emit the next piece of a long construct whose start is already consumed.
    fn continuePiece(self: *Reader, kind: Continuation) Error!Event {
        while (true) {
            const terminator = kind.terminator();
            if (std.mem.indexOfPos(u8, self.input, self.pos, terminator)) |end| {
                const inner = self.input[self.pos..end];
                self.pos = end + terminator.len;
                self.stream.?.pending = null;
                return kind.event(inner);
            }
            if (self.atEof()) {
                const inner = self.input[self.pos..];
                self.pos = self.input.len;
                self.stream.?.pending = null;
                return kind.event(inner);
            }
            if (try self.fillMore()) continue;
            return self.piece(kind);
        }
    }

    /// Emit what the full window holds of a long construct, keeping back enough
    /// bytes that a terminator split across reads is still found.
    fn piece(self: *Reader, kind: Continuation) Event {
        const keep = kind.terminator().len - 1;
        const end = @max(self.pos, self.input.len - keep);
        const inner = self.input[self.pos..end];
        self.pos = end;
        self.stream.?.pending = kind;
        return kind.event(inner);
    }

    fn rest(self: *const Reader) []const u8 {
        return self.input[self.pos..];
    }

    /// Whether the input at the cursor starts with `needle`, reading more when
    /// the window ends inside a possible match.
    fn startsWith(self: *const Reader, needle: []const u8) error{NeedMore}!bool {
        const available = self.rest();
        if (available.len >= needle.len) return std.mem.startsWith(u8, available, needle);
        if (!std.mem.eql(u8, available, needle[0..available.len])) return false;
        if (self.atEof()) return false;
        return error.NeedMore;
    }

    /// Find `needle` at or after the cursor; returns the end of input if absent
    /// (lenient: an unterminated construct runs to EOF).
    fn indexOfOrEnd(self: *const Reader, needle: []const u8) error{NeedMore}!usize {
        if (std.mem.indexOfPos(u8, self.input, self.pos, needle)) |i| return i;
        if (self.atEof()) return self.input.len;
        return error.NeedMore;
    }

    const TokenError = Error || error{NeedMore};

    fn token(self: *Reader) TokenError!Event {
        if (self.input[self.pos] != '<') {
            // Character data up to the next tag.
            const start = self.pos;
            const lt = std.mem.indexOfScalarPos(u8, self.input, self.pos, '<') orelse
                (if (self.atEof()) self.input.len else return error.NeedMore);
            self.pos = lt;
            return .{ .text = self.input[start..lt] };
        }

        // A markup construct begins at '<'.
        if (try self.startsWith("<!--")) {
            self.pos += "<!--".len;
            const start = self.pos;
            const end = try self.indexOfOrEnd("-->");
            const inner = self.input[start..end];
            self.pos = if (end < self.input.len) end + "-->".len else end;
            return .{ .comment = inner };
        }
        if (try self.startsWith("<![CDATA[")) {
            self.pos += "<![CDATA[".len;
            const start = self.pos;
            const end = try self.indexOfOrEnd("]]>");
            const inner = self.input[start..end];
            self.pos = if (end < self.input.len) end + "]]>".len else end;
            return .{ .cdata = inner };
        }
        if (try self.startsWith("<!")) {
            self.pos += "<!".len;
            const start = self.pos;
            const end = try self.indexOfOrEnd(">");
            const inner = self.input[start..end];
            self.pos = if (end < self.input.len) end + 1 else end;
            return .{ .declaration = inner };
        }
        if (try self.startsWith("<?")) {
            self.pos += "<?".len;
            const start = self.pos;
            // Prefer "?>" but tolerate a bare ">". Deciding needs the whole rest
            // of the document, so a stream reads on until it finds "?>".
            const q = std.mem.indexOfPos(u8, self.input, self.pos, "?>");
            if (q == null and !self.atEof()) return error.NeedMore;
            const end = q orelse try self.indexOfOrEnd(">");
            const inner = self.input[start..end];
            self.pos = if (q != null) end + "?>".len else (if (end < self.input.len) end + 1 else end);
            return .{ .processing_instruction = inner };
        }
        if (try self.startsWith("</")) {
            self.pos += "</".len;
            const name = try self.readName();
            // Skip to the closing '>'.
            const end = try self.indexOfOrEnd(">");
            self.pos = if (end < self.input.len) end + 1 else end;
            return .{ .close = name };
        }

        // A start tag: '<' name attributes ('>' | '/>').
        self.pos += 1; // consume '<'
        const name = try self.readName();
        if (name.len == 0) {
            // A stray '<' that is not a tag; treat the '<' as text so we make
            // progress instead of looping.
            return .{ .text = self.input[self.pos - 1 .. self.pos] };
        }
        self.attributes.clearRetainingCapacity();
        var self_closing = false;
        while (!try self.endAt(self.pos)) {
            try self.skipWhitespace();
            if (try self.endAt(self.pos)) break;
            const c = self.input[self.pos];
            if (c == '>') {
                self.pos += 1;
                break;
            }
            if (c == '/') {
                self.pos += 1;
                try self.skipWhitespace();
                if (!try self.endAt(self.pos) and self.input[self.pos] == '>') self.pos += 1;
                self_closing = true;
                break;
            }
            // An attribute: name [ '=' value ].
            const attr_name = try self.readName();
            if (attr_name.len == 0) {
                // Not a valid attribute char; skip one byte to avoid stalling.
                self.pos += 1;
                continue;
            }
            try self.skipWhitespace();
            var value: []const u8 = "";
            if (!try self.endAt(self.pos) and self.input[self.pos] == '=') {
                self.pos += 1;
                try self.skipWhitespace();
                value = try self.readAttributeValue();
            }
            try self.attributes.append(self.allocator, .{ .name = attr_name, .value = value });
        }

        const element: Element = .{ .name = name, .attributes = self.attributes.items };
        return if (self_closing) .{ .self_closing = element } else .{ .open = element };
    }

    fn skipWhitespace(self: *Reader) error{NeedMore}!void {
        while (!try self.endAt(self.pos) and isSpace(self.input[self.pos])) self.pos += 1;
    }

    /// Read an element or attribute name: everything up to whitespace or one of
    /// the tag-structural characters.
    fn readName(self: *Reader) error{NeedMore}![]const u8 {
        const start = self.pos;
        while (!try self.endAt(self.pos)) {
            const c = self.input[self.pos];
            if (isSpace(c) or c == '>' or c == '/' or c == '=' or c == '<') break;
            self.pos += 1;
        }
        return self.input[start..self.pos];
    }

    fn readAttributeValue(self: *Reader) error{NeedMore}![]const u8 {
        if (try self.endAt(self.pos)) return "";
        const quote = self.input[self.pos];
        if (quote == '"' or quote == '\'') {
            self.pos += 1;
            const start = self.pos;
            const end = std.mem.indexOfScalarPos(u8, self.input, self.pos, quote) orelse
                (if (self.atEof()) self.input.len else return error.NeedMore);
            self.pos = if (end < self.input.len) end + 1 else end;
            return self.input[start..end];
        }
        // Unquoted value: up to whitespace, '>' or '/'.
        const start = self.pos;
        while (!try self.endAt(self.pos)) {
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
pub fn decodeInto(out: *std.ArrayList(u8), allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error!void {
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
pub fn decode(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
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

// ---- streaming tests ----------------------------------------------------

/// `text` repeated `n` times, at comptime (Zig 0.17 has no `**`).
fn repeat(comptime text: []const u8, comptime n: usize) *const [text.len * n]u8 {
    const out = comptime blk: {
        @setEvalBranchQuota(10 * text.len * n + 1000);
        var buf: [text.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(buf[i * text.len ..][0..text.len], text);
        break :blk buf;
    };
    return &out;
}

/// An event copied out of the reader, so it outlives the next `next` call.
const OwnedEvent = struct {
    tag: std.meta.Tag(Event),
    text: []const u8,
    attributes: []const Attribute = &.{},

    fn eql(a: OwnedEvent, b: OwnedEvent) bool {
        if (a.tag != b.tag or !std.mem.eql(u8, a.text, b.text)) return false;
        if (a.attributes.len != b.attributes.len) return false;
        for (a.attributes, b.attributes) |x, y| {
            if (!std.mem.eql(u8, x.name, y.name) or !std.mem.eql(u8, x.value, y.value)) return false;
        }
        return true;
    }
};

fn own(arena: std.mem.Allocator, event: Event) !OwnedEvent {
    return switch (event) {
        .open, .self_closing => |element| blk: {
            const attributes = try arena.alloc(Attribute, element.attributes.len);
            for (attributes, element.attributes) |*dst, src| {
                dst.* = .{ .name = try arena.dupe(u8, src.name), .value = try arena.dupe(u8, src.value) };
            }
            break :blk .{ .tag = event, .text = try arena.dupe(u8, element.name), .attributes = attributes };
        },
        inline else => |text, tag| .{ .tag = tag, .text = try arena.dupe(u8, text) },
    };
}

fn drain(arena: std.mem.Allocator, reader: *Reader) ![]OwnedEvent {
    var events: std.ArrayList(OwnedEvent) = .empty;
    while (try reader.next()) |event| try events.append(arena, try own(arena, event));
    return events.items;
}

fn sliceEvents(arena: std.mem.Allocator, input: []const u8) ![]OwnedEvent {
    var reader = Reader.init(std.testing.allocator, input);
    defer reader.deinit();
    return drain(arena, &reader);
}

/// Tokenize `input` through a source that hands over one byte per read.
fn oneByteEvents(arena: std.mem.Allocator, input: []const u8, buffer_size: usize) ![]OwnedEvent {
    var source: std.testing.Reader = .init(&.{}, &.{.{ .buffer = input }});
    source.artificial_limit = .limited(1);
    var reader = try Reader.initStream(std.testing.allocator, &source.interface, .{ .buffer_size = buffer_size });
    defer reader.deinit();
    return drain(arena, &reader);
}

fn expectSameEvents(want: []const OwnedEvent, got: []const OwnedEvent) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        if (!w.eql(g)) {
            std.debug.print("want {t} \"{s}\", got {t} \"{s}\"\n", .{ w.tag, w.text, g.tag, g.text });
            return error.TestExpectedEqual;
        }
    }
}

const corpus = [_][]const u8{
    "",
    "<a>hello</a>",
    "<x a=\"1\" b='2' c=3 d>",
    "<br/><img src=\"x\" />",
    "<!--c--><![CDATA[<raw>]]><?pi go?><!DOCTYPE html>",
    "<a><!-- never closed",
    "<a href=\"?x=1&amp;y=2\">",
    "<r><a x=\"1\">t1</a><b/>t2</r>",
    "a < b",
    "trailing <",
    "<!",
    "<!-",
    "<![CDATA",
    "<?php echo 1 > after <b>bold</b>",
    "<?a > b ?> c",
    "<a b=\"unterminated",
    "<a b='x' / c>",
    "<a/ >",
    "<a / ",
    "</close   junk >tail",
    "<a<b>>",
    "<a =x>",
    "<a b = \"spaced\" >",
    "<!DOCTYPE note SYSTEM \"Note.dtd\"><!ENTITY x SYSTEM \"file:///etc/passwd\">&x;",
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\r\n" ++
        "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">" ++
        "<w:body><w:p><w:r><w:t xml:space=\"preserve\">Hello &amp; welcome</w:t></w:r></w:p>" ++
        "<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/></w:sectPr></w:body></w:document>",
    "<html><body onload=alert(1)><script>if (a < b && c > d) {}</script></body></html>",
    "<svg><![CDATA[ ]] ]> ]]]]><!-- -- -> --->x</svg>",
};

test "one byte at a time gives the same events as the slice API on the corpus" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (corpus) |doc| {
        const want = try sliceEvents(arena, doc);
        try expectSameEvents(want, try oneByteEvents(arena, doc, 4096));
        // A window barely larger than the document still sees every token whole.
        try expectSameEvents(want, try oneByteEvents(arena, doc, doc.len + 1));
    }
}

test "one byte at a time matches the slice API on random markup" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var prng = std.Random.DefaultPrng.init(0x5EED_F00D);
    const random = prng.random();
    const alphabet = "<>/=\"'&; !-?[]CDATAxy\n";
    var buffer: [200]u8 = undefined;
    var compared_small: usize = 0;
    var iteration: usize = 0;
    while (iteration < 3000) : (iteration += 1) {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        const len = random.uintLessThan(usize, buffer.len + 1);
        for (buffer[0..len]) |*byte| byte.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        const doc = buffer[0..len];
        const want = try sliceEvents(arena, doc);
        // A window larger than the document: refills on every byte, never full.
        try expectSameEvents(want, try oneByteEvents(arena, doc, 256));
        // A window smaller than the document, which must compact as it goes. Only
        // comparable when every token (plus the byte of lookahead that ends it)
        // fits, and with no processing instruction, whose end depends on the rest
        // of the document.
        if (maxTokenLen(doc) + 8 <= Reader.min_buffer_size and std.mem.indexOf(u8, doc, "<?") == null) {
            try expectSameEvents(want, try oneByteEvents(arena, doc, Reader.min_buffer_size));
            compared_small += 1;
        }
    }
    try std.testing.expect(compared_small > 100);
}

/// The longest stretch of input one slice-API token consumes.
fn maxTokenLen(doc: []const u8) usize {
    var reader = Reader.init(std.testing.allocator, doc);
    defer reader.deinit();
    var longest: usize = 0;
    var before: usize = 0;
    while (reader.next() catch return std.math.maxInt(usize)) |_| {
        longest = @max(longest, reader.pos - before);
        before = reader.pos;
    }
    return longest;
}

/// Concatenate the payloads of consecutive events of one kind.
fn joinRuns(arena: std.mem.Allocator, events: []const OwnedEvent) ![]OwnedEvent {
    var out: std.ArrayList(OwnedEvent) = .empty;
    for (events) |event| {
        const mergeable = switch (event.tag) {
            .text, .comment, .cdata, .declaration, .processing_instruction => true,
            else => false,
        };
        if (mergeable and out.items.len > 0 and out.items[out.items.len - 1].tag == event.tag) {
            const last = &out.items[out.items.len - 1];
            last.text = try std.mem.concat(arena, u8, &.{ last.text, event.text });
        } else try out.append(arena, event);
    }
    return out.items;
}

test "constructs longer than the buffer arrive in pieces that join to the slice result" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try std.mem.concat(arena, u8, &.{
        "<a>",          repeat("x", 1000),   "</a>",
        "<!--",         repeat("a->-", 125), "-->",
        "<![CDATA[",    repeat("]]]", 200),  "]]>",
        "<!",           repeat("d", 300),    ">",
        "<?",           repeat("p>", 200),   "?>",
        "<b c=\"1\"/>", "<!--",              repeat("y", 999),
    });
    const want = try sliceEvents(arena, doc);
    for ([_]usize{ 64, 65, 100, 257 }) |size| {
        const got = try oneByteEvents(arena, doc, size);
        try std.testing.expect(got.len > want.len);
        try expectSameEvents(try joinRuns(arena, want), try joinRuns(arena, got));
    }
}

test "a tag longer than the buffer is TokenTooLong" {
    const doc = "<a x=\"" ++ repeat("v", 200) ++ "\">";
    var source: std.Io.Reader = .fixed(doc);
    var reader = try Reader.initStream(std.testing.allocator, &source, .{ .buffer_size = 64 });
    defer reader.deinit();
    try std.testing.expectError(error.TokenTooLong, reader.next());
}

test "offset tracks the document position across refills" {
    var source: std.testing.Reader = .init(&.{}, &.{.{ .buffer = "<a>" ++ repeat("t", 100) ++ "</a>" }});
    source.artificial_limit = .limited(7);
    var reader = try Reader.initStream(std.testing.allocator, &source.interface, .{ .buffer_size = 64 });
    defer reader.deinit();
    while (try reader.next()) |_| {}
    try std.testing.expectEqual(@as(u64, 107), reader.offset());
}

/// Streams `unit` over and over until `total` bytes, then `tail`.
const RepeatingSource = struct {
    interface: std.Io.Reader,
    unit: []const u8,
    tail: []const u8,
    total: u64,
    produced: u64 = 0,

    fn init(buffer: []u8, unit: []const u8, tail: []const u8, total: u64) RepeatingSource {
        return .{
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
            .unit = unit,
            .tail = tail,
            .total = total,
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *RepeatingSource = @alignCast(@fieldParentPtr("interface", r));
        const bytes = if (self.produced < self.total) blk: {
            const at: usize = @intCast(self.produced % self.unit.len);
            const chunk = self.unit[at..];
            break :blk chunk[0..@intCast(@min(chunk.len, self.total - self.produced))];
        } else blk: {
            const at: usize = @intCast(self.produced - self.total);
            if (at == self.tail.len) return error.EndOfStream;
            break :blk self.tail[at..];
        };
        const n = try w.write(limit.sliceConst(bytes));
        self.produced += n;
        return n;
    }
};

/// Tracks the peak number of bytes outstanding.
const PeakAllocator = struct {
    parent: std.mem.Allocator,
    current: usize = 0,
    peak: usize = 0,

    fn allocator(self: *PeakAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn grow(self: *PeakAllocator, old: usize, new: usize) void {
        self.current = self.current - old + new;
        self.peak = @max(self.peak, self.current);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        const p = self.parent.rawAlloc(len, alignment, ra) orelse return null;
        self.grow(0, len);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        if (!self.parent.rawResize(memory, alignment, new_len, ra)) return false;
        self.grow(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        const p = self.parent.rawRemap(memory, alignment, new_len, ra) orelse return null;
        self.grow(memory.len, new_len);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ra);
        self.grow(memory.len, 0);
    }
};

test "memory stays bounded on a 100 MB document" {
    const gpa = std.testing.allocator;
    // One unit: small markup, then a comment and a text run each longer than the buffer.
    const small = "<w:p w:rsidR=\"00A1\"><w:r><w:t xml:space=\"preserve\">cell &amp; text</w:t></w:r></w:p>" ++
        "<?pi x?><![CDATA[c]]><!-- note --><br/>\n";
    var unit_list: std.ArrayList(u8) = .empty;
    defer unit_list.deinit(gpa);
    for (0..200) |_| try unit_list.appendSlice(gpa, small);
    try unit_list.appendSlice(gpa, "<!--");
    try unit_list.appendNTimes(gpa, 'c', 100 * 1024);
    try unit_list.appendSlice(gpa, "-->");
    try unit_list.appendNTimes(gpa, 't', 90 * 1024);
    const unit = unit_list.items;
    var source_buffer: [8192]u8 = undefined;
    const total: u64 = 100 * 1024 * 1024;
    var source: RepeatingSource = .init(&source_buffer, unit, "</root>", total);

    var peak: PeakAllocator = .{ .parent = gpa };
    var reader = try Reader.initStream(peak.allocator(), &source.interface, .{});
    defer reader.deinit();

    var opens: u64 = 0;
    var text_bytes: u64 = 0;
    while (try reader.next()) |event| switch (event) {
        .open => opens += 1,
        .text => |t| text_bytes += t.len,
        else => {},
    };

    const units = total / unit.len;
    try std.testing.expect(opens >= units * 200 * 3);
    try std.testing.expect(text_bytes >= units * 90 * 1024);
    try std.testing.expectEqual(total + "</root>".len, reader.offset());
    // The window plus a few attributes; nothing proportional to the document.
    try std.testing.expect(peak.peak <= 64 * 1024 + 4 * 1024);
}
