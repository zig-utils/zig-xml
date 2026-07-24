//! zig-xml — a small, lenient, allocation-light XML/HTML tokenizer.
//!
//! Public surface:
//! - `Reader`, `Event`, `Element`, `Attribute` — the pull tokenizer.
//! - `decode` / `decodeInto` — character-reference decoding.
//! - `entity` — the underlying HTML5 named-entity table.

const xml = @import("xml.zig");

pub const Reader = xml.Reader;
pub const Event = xml.Event;
pub const Element = xml.Element;
pub const Attribute = xml.Attribute;
pub const decode = xml.decode;
pub const decodeInto = xml.decodeInto;
pub const Error = xml.Error;
pub const entity = xml.entity;

test {
    _ = xml;
    _ = @import("entity.zig");
}
