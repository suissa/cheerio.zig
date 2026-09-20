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
pub const Cheerio = @import("cheerio.zig").Cheerio;
pub const CheerioDocument = @import("cheerio.zig").Document;
pub const load = @import("cheerio.zig").load;

test {
    _ = @import("dom.zig");
    _ = @import("dsl.zig");
    _ = @import("select.zig");
    _ = @import("cheerio.zig");
}
