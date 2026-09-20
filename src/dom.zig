const std = @import("std");
const mem = std.mem;
const ArrayList = std.array_list.Managed;
const StringHashMap = std.StringHashMap;

/// A minimal, general-purpose DOM tree used by the `dsl` and `select` modules.
/// Unlike `node.zig` (which mirrors the exact WHATWG DOM shape for the spec
/// parser), this is a small tree optimized for building markup at comptime
/// and querying it with CSS-like selectors, in the spirit of cheerio's `$`.
pub const Node = struct {
    const Self = @This();

    /// The tag name, e.g. "div". The sentinel tag `"#text"` marks a text node.
    tag: []const u8,
    attrs: StringHashMap([]const u8),
    children: ArrayList(*Node),
    /// Only set (and only meaningful) on `"#text"` nodes.
    text: ?[]const u8 = null,
    parent: ?*Node = null,

    pub fn init(allocator: mem.Allocator, tag: []const u8) *Node {
        const node = allocator.create(Node) catch unreachable;
        node.* = Node{
            .tag = tag,
            .attrs = StringHashMap([]const u8).init(allocator),
            .children = ArrayList(*Node).init(allocator),
        };
        return node;
    }

    pub fn isText(self: *const Self) bool {
        return mem.eql(u8, self.tag, "#text");
    }

    pub fn appendChild(self: *Self, child: *Node) void {
        child.parent = self;
        self.children.append(child) catch unreachable;
    }

    pub fn attr(self: *const Self, name: []const u8) ?[]const u8 {
        return self.attrs.get(name);
    }

    pub fn hasClass(self: *const Self, class: []const u8) bool {
        const classes = self.attr("class") orelse return false;
        var it = mem.tokenizeScalar(u8, classes, ' ');
        while (it.next()) |c| {
            if (mem.eql(u8, c, class)) return true;
        }
        return false;
    }

    /// Concatenates this node's own text plus all descendant text nodes'
    /// content, matching cheerio/jQuery's `.text()` semantics.
    pub fn textContent(self: *const Self, allocator: mem.Allocator) ![]const u8 {
        var buf = ArrayList(u8).init(allocator);
        try self.collectText(&buf);
        return buf.toOwnedSlice();
    }

    fn collectText(self: *const Self, buf: *ArrayList(u8)) !void {
        if (self.isText()) {
            try buf.appendSlice(self.text orelse "");
            return;
        }
        for (self.children.items) |child| {
            try child.collectText(buf);
        }
    }

    /// Serializes this node (and its descendants) back to an HTML string.
    pub fn outerHtml(self: *const Self, allocator: mem.Allocator) ![]const u8 {
        var buf = ArrayList(u8).init(allocator);
        try self.writeHtml(&buf);
        return buf.toOwnedSlice();
    }

    fn writeHtml(self: *const Self, buf: *ArrayList(u8)) !void {
        if (self.isText()) {
            try buf.appendSlice(self.text orelse "");
            return;
        }

        try buf.append('<');
        try buf.appendSlice(self.tag);

        var it = self.attrs.iterator();
        while (it.next()) |entry| {
            try buf.append(' ');
            try buf.appendSlice(entry.key_ptr.*);
            try buf.appendSlice("=\"");
            try buf.appendSlice(entry.value_ptr.*);
            try buf.append('"');
        }
        try buf.append('>');

        for (self.children.items) |child| {
            try child.writeHtml(buf);
        }

        try buf.appendSlice("</");
        try buf.appendSlice(self.tag);
        try buf.append('>');
    }
};

test "Node.textContent concatenates nested text" {
    const allocator = std.testing.allocator;
    const div = Node.init(allocator, "div");
    defer freeTree(allocator, div);

    const p = Node.init(allocator, "p");
    div.appendChild(p);
    const t1 = Node.init(allocator, "#text");
    t1.text = "Hello, ";
    p.appendChild(t1);
    const t2 = Node.init(allocator, "#text");
    t2.text = "world!";
    p.appendChild(t2);

    const text = try div.textContent(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hello, world!", text);
}

test "Node.hasClass" {
    const allocator = std.testing.allocator;
    const div = Node.init(allocator, "div");
    defer freeTree(allocator, div);
    try div.attrs.put("class", "foo bar");
    try std.testing.expect(div.hasClass("foo"));
    try std.testing.expect(div.hasClass("bar"));
    try std.testing.expect(!div.hasClass("baz"));
}

fn freeTree(allocator: mem.Allocator, node: *Node) void {
    for (node.children.items) |child| freeTree(allocator, child);
    node.children.deinit();
    node.attrs.deinit();
    allocator.destroy(node);
}
