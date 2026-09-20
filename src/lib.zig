const std = @import("std");
pub const node = @import("node.zig");
pub const Token = @import("token.zig").Token;
pub const Parser = @import("parser.zig").Parser;
pub const Tokenizer = @import("tokenizer.zig").Tokenizer;
pub const ParseError = @import("parse_error.zig").ParseError;

/// The cheerio-style DSL: a comptime element builder (`dsl.el`/`dsl.text`,
/// materialized with `dsl.render`) plus a jQuery-like `Selection`/`select`
/// for querying the resulting tree with CSS selectors.
pub const dom = @import("dom.zig");
pub const dsl = @import("dsl.zig");
pub const select = @import("select.zig").select;
pub const Selection = @import("select.zig").Selection;
/// `zhtml.load(allocator, root)`, mirroring `cheerio.load(html)`: sets the
/// document that bare `$(...)` calls (see below) operate on.
pub const load = @import("select.zig").load;
/// The cheerio-style `$(...)` call. Requires `load()` to have been called
/// first. See `select.zig`'s `@"$"` doc comment for the full contract.
pub const @"$" = @import("select.zig").@"$";

test {
    _ = @import("dom.zig");
    _ = @import("dsl.zig");
    _ = @import("select.zig");
}
