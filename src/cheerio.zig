const std = @import("std");
const mem = std.mem;
const ArrayList = std.array_list.Managed;
const dom = @import("dom.zig");
const select_mod = @import("select.zig");

pub const Document = struct {
    allocator: mem.Allocator,
    root: *dom.Node,
    source: []u8,

    pub fn deinit(self: *Document) void {
        dom.destroyTree(self.allocator, self.root);
        self.allocator.free(self.source);
        self.root = undefined;
        self.source = undefined;
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

pub const Cheerio = Document;

pub fn load(allocator: mem.Allocator, source: []const u8) !Document {
    const root = dom.Node.init(allocator, "#root");
    errdefer dom.destroyTree(allocator, root);

    const owned_source = try allocator.dupe(u8, source);
    errdefer allocator.free(owned_source);

    var stack = ArrayList(*dom.Node).init(allocator);
    defer stack.deinit();
    try stack.append(root);

    var pos: usize = 0;
    while (pos < document.source.len) {
        const parent = stack.items[stack.items.len - 1];

        if (isRawTextElement(parent.tag)) {
            const close = findClosingTag(document.source, pos, parent.tag);
            const end = close orelse document.source.len;
            if (end > pos) {
                const text = dom.Node.init(allocator, "#text");
                text.text = document.source[pos..end];
                parent.appendChild(text);
            }
            pos = end;
            if (close == null) break;
        }

        if (document.source[pos] != '<') {
            const start = pos;
            while (pos < document.source.len and document.source[pos] != '<') pos += 1;
            const text = dom.Node.init(allocator, "#text");
            text.text = document.source[start..pos];
            parent.appendChild(text);
            continue;
        }

        if (mem.startsWith(u8, document.source[pos..], "<!--")) {
            const end = mem.indexOf(u8, document.source[pos + 4 ..], "-->") orelse document.source.len - (pos + 4);
            pos = if (end == document.source.len - (pos + 4)) document.source.len else pos + 4 + end + 3;
            continue;
        }

        if (pos + 1 < document.source.len and document.source[pos + 1] == '/') {
            pos += 2;
            skipSpace(document.source, &pos);
            const name_start = pos;
            while (pos < document.source.len and isNameChar(document.source[pos])) pos += 1;
            const name_end = pos;
            while (pos < document.source.len and document.source[pos] != '>') pos += 1;
            if (pos < document.source.len) pos += 1;

            if (stack.items.len > 1 and asciiEqlIgnoreCase(stack.items[stack.items.len - 1].tag, document.source[name_start..name_end])) {
                _ = stack.pop();
            } else if (stack.items.len > 1) {
                var i = stack.items.len;
                while (i > 1) {
                    i -= 1;
                    if (asciiEqlIgnoreCase(stack.items[i].tag, document.source[name_start..name_end])) {
                        stack.shrinkRetainingCapacity(i);
                        break;
                    }
                }
            }
            continue;
        }

        pos += 1;
        if (pos < document.source.len and (document.source[pos] == '!' or document.source[pos] == '?')) {
            while (pos < document.source.len and document.source[pos] != '>') pos += 1;
            if (pos < document.source.len) pos += 1;
            continue;
        }

        skipSpace(document.source, &pos);
        const name_start = pos;
        while (pos < document.source.len and isNameChar(document.source[pos])) pos += 1;
        if (name_start == pos) {
            const text = dom.Node.init(allocator, "#text");
            text.text = "<";
            parent.appendChild(text);
            continue;
        }

        const element = dom.Node.init(allocator, document.source[name_start..pos]);
        var self_closing = false;
        while (pos < document.source.len) {
            skipSpace(document.source, &pos);
            if (pos >= document.source.len) break;
            if (document.source[pos] == '>') {
                pos += 1;
                break;
            }
            if (document.source[pos] == '/' and pos + 1 < document.source.len and document.source[pos + 1] == '>') {
                self_closing = true;
                pos += 2;
                break;
            }

            const attr_start = pos;
            while (pos < document.source.len and isNameChar(document.source[pos])) pos += 1;
            if (attr_start == pos) {
                pos += 1;
                continue;
            }
            const attr_name = document.source[attr_start..pos];
            skipSpace(document.source, &pos);
            var value: []const u8 = "";
            if (pos < document.source.len and document.source[pos] == '=') {
                pos += 1;
                skipSpace(document.source, &pos);
                if (pos < document.source.len and (document.source[pos] == '\'' or document.source[pos] == '"')) {
                    const quote = document.source[pos];
                    pos += 1;
                    const value_start = pos;
                    while (pos < document.source.len and document.source[pos] != quote) pos += 1;
                    value = document.source[value_start..pos];
                    if (pos < document.source.len) pos += 1;
                } else {
                    const value_start = pos;
                    while (pos < document.source.len and document.source[pos] != '>' and !isSpace(document.source[pos])) pos += 1;
                    value = document.source[value_start..pos];
                }
            }
            try element.attrs.put(attr_name, value);
        }

        parent.appendChild(element);
        if (!self_closing and !isVoidElement(element.tag)) try stack.append(element);
    }

    return .{
        .allocator = allocator,
        .root = root,
        .source = owned_source,
    };
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

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

fn isRawTextElement(tag: []const u8) bool {
    return asciiEqlIgnoreCase(tag, "script") or asciiEqlIgnoreCase(tag, "style") or
        asciiEqlIgnoreCase(tag, "textarea") or asciiEqlIgnoreCase(tag, "title");
}

fn findClosingTag(source: []const u8, start: usize, tag: []const u8) ?usize {
    var i = start;
    while (i + 2 < source.len) : (i += 1) {
        if (source[i] != '<' or source[i + 1] != '/') continue;
        var j = i + 2;
        while (j < source.len and isNameChar(source[j])) j += 1;
        if (asciiEqlIgnoreCase(source[i + 2 .. j], tag)) return i;
    }
    return null;
}

fn isVoidElement(tag: []const u8) bool {
    return asciiEqlIgnoreCase(tag, "area") or asciiEqlIgnoreCase(tag, "base") or
        asciiEqlIgnoreCase(tag, "br") or asciiEqlIgnoreCase(tag, "col") or
        asciiEqlIgnoreCase(tag, "embed") or asciiEqlIgnoreCase(tag, "hr") or
        asciiEqlIgnoreCase(tag, "img") or asciiEqlIgnoreCase(tag, "input") or
        asciiEqlIgnoreCase(tag, "link") or asciiEqlIgnoreCase(tag, "meta") or
        asciiEqlIgnoreCase(tag, "param") or asciiEqlIgnoreCase(tag, "source") or
        asciiEqlIgnoreCase(tag, "track") or asciiEqlIgnoreCase(tag, "wbr");
}

test "load owns the source buffer and parses raw text elements" {
    const input = try std.testing.allocator.dupe(u8, "<SCRIPT>if (a < b) x();</SCRIPT><IMG src=x/y>");
    defer std.testing.allocator.free(input);

    var document = try load(std.testing.allocator, input);
    defer document.deinit();

    var script = try document.select("script");
    defer script.deinit();
    const text = try script.text();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("if (a < b) x();", text);

    var image = try document.select("img");
    defer image.deinit();
    try std.testing.expectEqualStrings("x/y", image.attr("src").?);
}
