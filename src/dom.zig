const std = @import("std");
const mem = std.mem;
const ArrayList = std.array_list.Managed;
const StringHashMap = std.StringHashMap;

pub const Node = struct {
    const Self = @This();

    tag: []const u8,
    allocator: mem.Allocator,
    attrs: StringHashMap([]const u8),
    children: ArrayList(*Node),
    text: ?[]const u8 = null,
    parent: ?*Node = null,

    pub fn init(allocator: mem.Allocator, tag: []const u8) *Node {
        const node = allocator.create(Node) catch unreachable;
        node.* = .{
            .tag = tag,
            .allocator = allocator,
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

    pub fn prependChild(self: *Self, child: *Node) void {
        child.parent = self;
        self.children.insert(0, child) catch unreachable;
    }

    pub fn removeChild(self: *Self, child: *Node) bool {
        for (self.children.items, 0..) |candidate, i| {
            if (candidate == child) {
                _ = self.children.orderedRemove(i);
                child.parent = null;
                return true;
            }
        }
        return false;
    }

    pub fn clearChildren(self: *Self) void {
        for (self.children.items) |child| destroyTree(self.allocator, child);
        self.children.clearRetainingCapacity();
    }

    pub fn attr(self: *const Self, name: []const u8) ?[]const u8 {
        return self.attrs.get(name);
    }

    pub fn hasClass(self: *const Self, class: []const u8) bool {
        const classes = self.attr("class") orelse return false;
        var it = mem.tokenizeAny(u8, classes, " \t\n\r\x0c");
        while (it.next()) |c| {
            if (mem.eql(u8, c, class)) return true;
        }
        return false;
    }

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
        for (self.children.items) |child| try child.collectText(buf);
    }

    pub fn outerHtml(self: *const Self, allocator: mem.Allocator) ![]const u8 {
        var buf = ArrayList(u8).init(allocator);
        try self.writeHtml(&buf);
        return buf.toOwnedSlice();
    }

    pub fn innerHtml(self: *const Self, allocator: mem.Allocator) ![]const u8 {
        var buf = ArrayList(u8).init(allocator);
        for (self.children.items) |child| try child.writeHtml(&buf);
        return buf.toOwnedSlice();
    }

    fn writeHtml(self: *const Self, buf: *ArrayList(u8)) !void {
        if (self.isText()) {
            try appendEscaped(buf, self.text orelse "", false);
            return;
        }

        try buf.append('<');
        try buf.appendSlice(self.tag);

        var it = self.attrs.iterator();
        while (it.next()) |entry| {
            try buf.append(' ');
            try buf.appendSlice(entry.key_ptr.*);
            try buf.appendSlice("=\"");
            try appendEscaped(buf, entry.value_ptr.*, true);
            try buf.append('"');
        }
        try buf.append('>');

        for (self.children.items) |child| try child.writeHtml(buf);

        if (!isVoidElement(self.tag)) {
            try buf.appendSlice("</");
            try buf.appendSlice(self.tag);
            try buf.append('>');
        }
    }

    fn appendEscaped(buf: *ArrayList(u8), value: []const u8, attribute: bool) !void {
        for (value) |c| {
            switch (c) {
                '&' => try buf.appendSlice("&amp;"),
                '<' => try buf.appendSlice("&lt;"),
                '>' => try buf.appendSlice("&gt;"),
                '"' => if (attribute) try buf.appendSlice("&quot;") else try buf.append(c),
                else => try buf.append(c),
            }
        }
    }
};

fn isVoidElement(tag: []const u8) bool {
    return mem.eql(u8, tag, "area") or mem.eql(u8, tag, "base") or
        mem.eql(u8, tag, "br") or mem.eql(u8, tag, "col") or
        mem.eql(u8, tag, "embed") or mem.eql(u8, tag, "hr") or
        mem.eql(u8, tag, "img") or mem.eql(u8, tag, "input") or
        mem.eql(u8, tag, "link") or mem.eql(u8, tag, "meta") or
        mem.eql(u8, tag, "param") or mem.eql(u8, tag, "source") or
        mem.eql(u8, tag, "track") or mem.eql(u8, tag, "wbr");
}

pub fn destroyTree(allocator: mem.Allocator, node: *Node) void {
    for (node.children.items) |child| destroyTree(allocator, child);
    node.children.deinit();
    node.attrs.deinit();
    allocator.destroy(node);
}

pub fn cloneTree(allocator: mem.Allocator, source: *const Node) !*Node {
    const copy = Node.init(allocator, source.tag);
    errdefer destroyTree(allocator, copy);
    copy.text = source.text;
    var attrs = source.attrs.iterator();
    while (attrs.next()) |entry| try copy.attrs.put(entry.key_ptr.*, entry.value_ptr.*);
    for (source.children.items) |child| try copy.appendChild(try cloneTree(allocator, child));
    return copy;
}

test "Node.textContent concatenates nested text" {
    const allocator = std.testing.allocator;
    const div = Node.init(allocator, "div");
    defer destroyTree(allocator, div);
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

test "Node.hasClass accepts HTML whitespace" {
    const allocator = std.testing.allocator;
    const div = Node.init(allocator, "div");
    defer destroyTree(allocator, div);
    try div.attrs.put("class", "foo\tbar");
    try std.testing.expect(div.hasClass("foo"));
    try std.testing.expect(div.hasClass("bar"));
}

test "void elements are not serialized with closing tags" {
    const allocator = std.testing.allocator;
    const img = Node.init(allocator, "img");
    defer destroyTree(allocator, img);
    const html = try img.outerHtml(allocator);
    defer allocator.free(html);
    try std.testing.expectEqualStrings("<img>", html);
}
