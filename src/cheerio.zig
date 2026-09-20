const std = @import("std");
const mem = std.mem;
const ArrayList = std.array_list.Managed;
const dom = @import("dom.zig");
const select_mod = @import("select.zig");

/// An owned document and the Cheerio-like query entry point.
///
/// This intentionally keeps ownership in one object: selections are views over
/// the document and must not outlive it, just like Cheerio selections are tied
/// to the loaded Cheerio instance.
pub const Document = struct {
    allocator: mem.Allocator,
    root: *dom.Node,

    pub fn deinit(self: *Document) void {
        dom.destroyTree(self.allocator, self.root);
        self.root = undefined;
    }

    pub fn select(self: *const Document, selector: []const u8) !select_mod.Selection {
        return select_mod.select(self.allocator, self.root, selector);
    }

    pub fn find(self: *const Document, selector: []const u8) !select_mod.Selection {
        return self.select(selector);
    }

    pub fn html(self: *const Document) ![]const u8 {
        return self.root.innerHtml(self.allocator);
    }
};

/// Public name matching the conceptual Cheerio instance.
pub const Cheerio = Document;

/// Parse a fragment/document and return an owned Cheerio-style document.
/// The tokenizer remains available separately for WHATWG conformance tests;
/// this lightweight tree builder is the ergonomic DOM API used by the DSL.
pub fn load(allocator: mem.Allocator, source: []const u8) !Document {
    const root = dom.Node.init(allocator, "#root");
    errdefer dom.destroyTree(allocator, root);

    var stack = ArrayList(*dom.Node).init(allocator);
    defer stack.deinit();
    try stack.append(root);

    var pos: usize = 0;
    while (pos < source.len) {
        const parent = stack.items[stack.items.len - 1];
        if (source[pos] != '<') {
            const start = pos;
            while (pos < source.len and source[pos] != '<') pos += 1;
            const text = dom.Node.init(allocator, "#text");
            text.text = source[start..pos];
            parent.appendChild(text);
            continue;
        }

        if (mem.startsWith(u8, source[pos..], "<!--")) {
            const end = mem.indexOf(u8, source[pos + 4..], "-->") orelse source.len - (pos + 4);
            pos = if (end == source.len - (pos + 4)) source.len else pos + 4 + end + 3;
            continue;
        }

        if (pos + 1 < source.len and source[pos + 1] == '/') {
            pos += 2;
            skipSpace(source, &pos);
            const name_start = pos;
            while (pos < source.len and isNameChar(source[pos])) pos += 1;
            const name_end = pos;
            while (pos < source.len and source[pos] != '>') pos += 1;
            if (pos < source.len) pos += 1;
            if (stack.items.len > 1 and mem.eql(u8, stack.items[stack.items.len - 1].tag, source[name_start..name_end])) {
                _ = stack.pop();
            } else if (stack.items.len > 1) {
                // HTML error recovery: close the nearest matching open tag.
                var i = stack.items.len;
                while (i > 1) {
                    i -= 1;
                    if (mem.eql(u8, stack.items[i].tag, source[name_start..name_end])) {
                        stack.shrinkRetainingCapacity(i);
                        break;
                    }
                }
            }
            continue;
        }

        pos += 1;
        if (pos < source.len and (source[pos] == '!' or source[pos] == '?')) {
            while (pos < source.len and source[pos] != '>') pos += 1;
            if (pos < source.len) pos += 1;
            continue;
        }

        skipSpace(source, &pos);
        const name_start = pos;
        while (pos < source.len and isNameChar(source[pos])) pos += 1;
        if (name_start == pos) {
            const text = dom.Node.init(allocator, "#text");
            text.text = "<";
            parent.appendChild(text);
            continue;
        }

        const element = dom.Node.init(allocator, source[name_start..pos]);
        var self_closing = false;
        while (pos < source.len) {
            skipSpace(source, &pos);
            if (pos >= source.len) break;
            if (source[pos] == '>') {
                pos += 1;
                break;
            }
            if (source[pos] == '/' and pos + 1 < source.len and source[pos + 1] == '>') {
                self_closing = true;
                pos += 2;
                break;
            }
            const attr_start = pos;
            while (pos < source.len and isNameChar(source[pos])) pos += 1;
            if (attr_start == pos) {
                pos += 1;
                continue;
            }
            const attr_name = source[attr_start..pos];
            skipSpace(source, &pos);
            var value: []const u8 = "";
            if (pos < source.len and source[pos] == '=') {
                pos += 1;
                skipSpace(source, &pos);
                if (pos < source.len and (source[pos] == '\'' or source[pos] == '"')) {
                    const quote = source[pos];
                    pos += 1;
                    const value_start = pos;
                    while (pos < source.len and source[pos] != quote) pos += 1;
                    value = source[value_start..pos];
                    if (pos < source.len) pos += 1;
                } else {
                    const value_start = pos;
                    while (pos < source.len and source[pos] != '>' and source[pos] != '/' and !isSpace(source[pos])) pos += 1;
                    value = source[value_start..pos];
                }
            }
            try element.attrs.put(attr_name, value);
        }

        parent.appendChild(element);
        if (!self_closing and !isVoidElement(element.tag)) try stack.append(element);
    }

    return .{ .allocator = allocator, .root = root };
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

fn skipSpace(source: []const u8, pos: *usize) void {
    while (pos.* < source.len and isSpace(source[pos.*])) pos.* += 1;
}

fn isNameChar(c: u8) bool {
    return !isSpace(c) and c != '/' and c != '>' and c != '=' and c != '<';
}

fn isVoidElement(tag: []const u8) bool {
    return mem.eql(u8, tag, "area") or mem.eql(u8, tag, "base") or
        mem.eql(u8, tag, "br") or mem.eql(u8, tag, "col") or
        mem.eql(u8, tag, "embed") or mem.eql(u8, tag, "hr") or
        mem.eql(u8, tag, "img") or mem.eql(u8, tag, "input") or
        mem.eql(u8, tag, "link") or mem.eql(u8, tag, "meta") or
        mem.eql(u8, tag, "param") or mem.eql(u8, tag, "source") or
        mem.eql(u8, tag, "track") or mem.eql(u8, tag, "wbr");
}

test "load parses HTML and exposes Cheerio-style selection" {
    var document = try load(std.testing.allocator, "<div id='app'><p class='x'>Hello</p><br></div>");
    defer document.deinit();
    var paragraphs = try document.select("#app p.x");
    defer paragraphs.deinit();
    try std.testing.expectEqual(@as(usize, 1), paragraphs.length());
    const value = try paragraphs.text();
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("Hello", value);
}
