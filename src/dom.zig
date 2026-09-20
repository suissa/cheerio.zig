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

    pub fn addClass(self: *Self, allocator: mem.Allocator, class: []const u8) !void {
        if (self.hasClass(class)) return;
        const existing = self.attr("class") orelse "";
        const new_value = if (existing.len == 0)
            try allocator.dupe(u8, class)
        else
            try std.fmt.allocPrint(allocator, "{s} {s}", .{ existing, class });
        try self.attrs.put("class", new_value);
    }

    pub fn removeClass(self: *Self, allocator: mem.Allocator, class: []const u8) !void {
        const existing = self.attr("class") orelse return;
        var buf = ArrayList(u8).init(allocator);
        var it = mem.tokenizeScalar(u8, existing, ' ');
        while (it.next()) |c| {
            if (mem.eql(u8, c, class)) continue;
            if (buf.items.len > 0) try buf.append(' ');
            try buf.appendSlice(c);
        }
        try self.attrs.put("class", try buf.toOwnedSlice());
    }

    /// Replaces this node's children with a single text node containing
    /// `value`, matching cheerio/jQuery's `.text(value)` setter semantics.
    pub fn setText(self: *Self, allocator: mem.Allocator, value: []const u8) !void {
        for (self.children.items) |child| destroyTree(allocator, child);
        self.children.clearAndFree();
        const t = Node.init(allocator, "#text");
        t.text = value;
        self.appendChild(t);
    }

    /// Destroys `node` and all of its descendants, freeing every allocation
    /// `Node.init`/`appendChild` made for them. Does not attempt to free
    /// attribute values, since those may be string literals rather than
    /// heap allocations (e.g. from the `dsl` builder) — callers that mutate
    /// attributes with allocated values (`addClass`/`removeClass`) are
    /// expected to own that allocator for the tree's lifetime (an arena is
    /// the natural fit).
    pub fn destroyTree(allocator: mem.Allocator, node: *Node) void {
        for (node.children.items) |child| destroyTree(allocator, child);
        node.children.deinit();
        node.attrs.deinit();
        allocator.destroy(node);
    }

    // -- DOM-style traversal properties, exposed as methods (Zig has no
    //    getter properties). Names match the standard DOM API so that code
    //    reading like cheerio/JS ports over with minimal translation. --

    pub fn tagName(self: *const Self) []const u8 {
        return self.tag;
    }

    pub fn parentNode(self: *const Self) ?*Node {
        return self.parent;
    }

    /// Only meaningful on `"#text"` nodes; mirrors `Node.nodeValue` in the DOM.
    pub fn nodeValue(self: *const Self) ?[]const u8 {
        return if (self.isText()) self.text else null;
    }

    pub fn childNodes(self: *const Self) []const *Node {
        return self.children.items;
    }

    pub fn firstChild(self: *const Self) ?*Node {
        if (self.children.items.len == 0) return null;
        return self.children.items[0];
    }

    pub fn lastChild(self: *const Self) ?*Node {
        if (self.children.items.len == 0) return null;
        return self.children.items[self.children.items.len - 1];
    }

    pub fn previousSibling(self: *const Self) ?*Node {
        const parent = self.parent orelse return null;
        const idx = indexOfChild(parent, self) orelse return null;
        if (idx == 0) return null;
        return parent.children.items[idx - 1];
    }

    pub fn nextSibling(self: *const Self) ?*Node {
        const parent = self.parent orelse return null;
        const idx = indexOfChild(parent, self) orelse return null;
        if (idx + 1 >= parent.children.items.len) return null;
        return parent.children.items[idx + 1];
    }

    fn indexOfChild(parent: *const Node, target: *const Node) ?usize {
        for (parent.children.items, 0..) |c, i| {
            if (@intFromPtr(c) == @intFromPtr(target)) return i;
        }
        return null;
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
    defer Node.destroyTree(allocator, div);

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
    defer Node.destroyTree(allocator, div);
    try div.attrs.put("class", "foo bar");
    try std.testing.expect(div.hasClass("foo"));
    try std.testing.expect(div.hasClass("bar"));
    try std.testing.expect(!div.hasClass("baz"));
}

test "Node traversal properties" {
    const allocator = std.testing.allocator;
    const ul = Node.init(allocator, "ul");
    defer Node.destroyTree(allocator, ul);

    const li1 = Node.init(allocator, "li");
    const li2 = Node.init(allocator, "li");
    const li3 = Node.init(allocator, "li");
    ul.appendChild(li1);
    ul.appendChild(li2);
    ul.appendChild(li3);

    try std.testing.expectEqualStrings("ul", ul.tagName());
    try std.testing.expectEqual(@as(?*Node, null), ul.parentNode());
    try std.testing.expectEqual(ul, li2.parentNode().?);
    try std.testing.expectEqual(li1, li2.parentNode().?.firstChild().?);
    try std.testing.expectEqual(li3, ul.lastChild().?);
    try std.testing.expectEqual(@as(usize, 3), ul.childNodes().len);

    try std.testing.expectEqual(@as(?*Node, null), li1.previousSibling());
    try std.testing.expectEqual(li2, li1.nextSibling().?);
    try std.testing.expectEqual(li1, li2.previousSibling().?);
    try std.testing.expectEqual(li3, li2.nextSibling().?);
    try std.testing.expectEqual(@as(?*Node, null), li3.nextSibling());

    const t = Node.init(allocator, "#text");
    t.text = "hi";
    li1.appendChild(t);
    try std.testing.expectEqualStrings("hi", t.nodeValue().?);
    try std.testing.expectEqual(@as(?[]const u8, null), li1.nodeValue());
}

test "Node.addClass / removeClass" {
    // addClass/removeClass allocate new "class" attribute values, which a
    // plain destroyTree doesn't (and can't safely) free; an arena is the
    // natural ownership model for a tree that mutates its own attributes.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const div = Node.init(allocator, "div");

    try div.addClass(allocator, "welcome");
    try std.testing.expect(div.hasClass("welcome"));
    try div.addClass(allocator, "welcome"); // no-op, already present
    try std.testing.expectEqualStrings("welcome", div.attr("class").?);

    try div.addClass(allocator, "loud");
    try std.testing.expect(div.hasClass("loud"));

    try div.removeClass(allocator, "welcome");
    try std.testing.expect(!div.hasClass("welcome"));
    try std.testing.expect(div.hasClass("loud"));
}

test "Node.setText replaces children with a single text node" {
    const allocator = std.testing.allocator;
    const h2 = Node.init(allocator, "h2");
    defer Node.destroyTree(allocator, h2);
    try h2.attrs.put("class", "title");

    try h2.setText(allocator, "Hello there!");
    const t = try h2.textContent(allocator);
    defer allocator.free(t);
    try std.testing.expectEqualStrings("Hello there!", t);
    try std.testing.expectEqual(@as(usize, 1), h2.children.items.len);
}

