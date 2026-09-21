const std = @import("std");
const mem = std.mem;
const ArrayList = std.array_list.Managed;
const dom = @import("dom.zig");

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

/// A single compound selector, e.g. the `div.row#main` in `div.row#main > p`.
/// Only tag/class/id/universal compounds are supported, joined by
/// descendant combinators (whitespace) between compounds — enough to cover
/// cheerio's most common selector usage.
const Compound = struct {
    tag: ?[]const u8 = null,
    id: ?[]const u8 = null,
    classes: []const []const u8 = &.{},

    fn matches(self: Compound, node: *const dom.Node) bool {
        if (node.isText()) return false;
        if (self.tag) |t| {
            if (!mem.eql(u8, t, "*") and !asciiEqlIgnoreCase(t, node.tag)) return false;
        }
        if (self.id) |id| {
            if (!mem.eql(u8, node.attr("id") orelse "", id)) return false;
        }
        for (self.classes) |c| {
            if (!node.hasClass(c)) return false;
        }
        return true;
    }
};

/// Parses one comma-free selector chain ("div.row p.item") into a list of
/// descendant `Compound`s, ordered outer-to-inner.
fn parseChain(allocator: mem.Allocator, selector: []const u8) ![]Compound {
    var compounds = ArrayList(Compound).init(allocator);
    var it = mem.tokenizeScalar(u8, selector, ' ');
    while (it.next()) |part| {
        try compounds.append(try parseCompound(allocator, part));
    }
    return compounds.toOwnedSlice();
}

fn parseCompound(allocator: mem.Allocator, part: []const u8) !Compound {
    var compound = Compound{};
    var classes = ArrayList([]const u8).init(allocator);

    var i: usize = 0;
    // Leading tag name (or universal "*"), if any.
    const start = i;
    while (i < part.len and part[i] != '.' and part[i] != '#') i += 1;
    if (i > start) compound.tag = part[start..i];

    while (i < part.len) {
        const marker = part[i];
        i += 1;
        const seg_start = i;
        while (i < part.len and part[i] != '.' and part[i] != '#') i += 1;
        const seg = part[seg_start..i];
        switch (marker) {
            '.' => try classes.append(seg),
            '#' => compound.id = seg,
            else => unreachable,
        }
    }

    compound.classes = try classes.toOwnedSlice();
    return compound;
}

/// Returns true if `node` is matched by `compound`, and its ancestor chain
/// (going up from `node`'s parent) satisfies the remaining preceding
/// compounds in `chain[0 .. chain.len - 1]`, in order — i.e. standard CSS
/// descendant-combinator matching.
fn matchesChain(node: *const dom.Node, chain: []const Compound, boundary: ?*const dom.Node) bool {
    if (chain.len == 0) return true;
    if (!chain[chain.len - 1].matches(node)) return false;

    var remaining = chain[0 .. chain.len - 1];
    var ancestor = node.parent;
    while (remaining.len > 0) {
        const current = ancestor orelse return false;
        if (boundary != null and current == boundary.?) return false;
        if (remaining[remaining.len - 1].matches(current)) {
            remaining = remaining[0 .. remaining.len - 1];
        }
        ancestor = current.parent;
    }
    return true;
}

fn collectMatches(allocator: mem.Allocator, node: *dom.Node, chain: []const Compound, out: *ArrayList(*dom.Node), boundary: ?*const dom.Node) !void {
    if (matchesChain(node, chain, boundary)) try out.append(node);
    for (node.children.items) |child| {
        try collectMatches(allocator, child, chain, out, boundary);
    }
}

/// A jQuery/cheerio-style wrapper around a set of matched nodes, supporting
/// the same chainable, batch-oriented API: `$(selector).find(...).text()`.
pub const Selection = struct {
    const Self = @This();

    allocator: mem.Allocator,
    nodes: []*dom.Node,

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.nodes);
    }

    pub fn length(self: Self) usize {
        return self.nodes.len;
    }

    pub fn get(self: Self, index: usize) ?*dom.Node {
        if (index >= self.nodes.len) return null;
        return self.nodes[index];
    }

    pub fn toArray(self: Self) ![]*dom.Node {
        const out = try self.allocator.alloc(*dom.Node, self.nodes.len);
        @memcpy(out, self.nodes);
        return out;
    }

    pub fn first(self: Self) !Self {
        const out = try self.allocator.alloc(*dom.Node, if (self.nodes.len > 0) 1 else 0);
        if (self.nodes.len > 0) out[0] = self.nodes[0];
        return Self{ .allocator = self.allocator, .nodes = out };
    }

    pub fn eq(self: Self, index: usize) !Self {
        const out = try self.allocator.alloc(*dom.Node, if (index < self.nodes.len) 1 else 0);
        if (index < self.nodes.len) out[0] = self.nodes[index];
        return Self{ .allocator = self.allocator, .nodes = out };
    }

    /// `.text()`: the concatenated text content of every matched node.
    pub fn text(self: Self) ![]const u8 {
        var buf = ArrayList(u8).init(self.allocator);
        for (self.nodes) |node| {
            const t = try node.textContent(self.allocator);
            defer self.allocator.free(t);
            try buf.appendSlice(t);
        }
        return buf.toOwnedSlice();
    }

    /// `.attr(name)`: the attribute value from the first matched node.
    pub fn attr(self: Self, name: []const u8) ?[]const u8 {
        if (self.nodes.len == 0) return null;
        return self.nodes[0].attr(name);
    }

    pub fn hasClass(self: Self, class: []const u8) bool {
        return self.nodes.len > 0 and self.nodes[0].hasClass(class);
    }

    pub fn is(self: Self, selector: []const u8) !bool {
        const filtered = try self.filter(selector);
        defer filtered.deinit();
        return filtered.length() > 0;
    }

    pub fn append(self: Self, child: *dom.Node) void {
        for (self.nodes) |node| {
            const copy = dom.cloneTree(self.allocator, child) catch unreachable;
            node.appendChild(copy);
        }
    }

    pub fn prepend(self: Self, child: *dom.Node) void {
        for (self.nodes) |node| {
            const copy = dom.cloneTree(self.allocator, child) catch unreachable;
            node.prependChild(copy);
        }
    }

    /// `.html()`: the serialized inner HTML of the first matched node.
    pub fn html(self: Self) !?[]const u8 {
        if (self.nodes.len == 0) return null;
        return try self.nodes[0].innerHtml(self.allocator);
    }

    pub fn outerHtml(self: Self) !?[]const u8 {
        if (self.nodes.len == 0) return null;
        return try self.nodes[0].outerHtml(self.allocator);
    }

    pub fn parent(self: Self) !Self {
        var out = ArrayList(*dom.Node).init(self.allocator);
        var seen = std.AutoHashMap(*dom.Node, void).init(self.allocator);
        defer seen.deinit();
        for (self.nodes) |node| {
            if (node.parent) |p| if (!seen.contains(p)) {
                try seen.put(p, {});
                try out.append(p);
            };
        }
        return Self{ .allocator = self.allocator, .nodes = try out.toOwnedSlice() };
    }

    pub fn children(self: Self) !Self {
        var out = ArrayList(*dom.Node).init(self.allocator);
        for (self.nodes) |node| {
            for (node.children.items) |child| {
                if (!child.isText()) try out.append(child);
            }
        }
        return Self{ .allocator = self.allocator, .nodes = try out.toOwnedSlice() };
    }

    pub fn next(self: Self) !Self {
        var out = ArrayList(*dom.Node).init(self.allocator);
        for (self.nodes) |node| {
            const p = node.parent orelse continue;
            for (p.children.items, 0..) |candidate, i| {
                if (candidate == node) {
                    var j = i + 1;
                    while (j < p.children.items.len and p.children.items[j].isText()) : (j += 1) {}
                    if (j < p.children.items.len) try out.append(p.children.items[j]);
                    break;
                }
            }
        }
        return Self{ .allocator = self.allocator, .nodes = try out.toOwnedSlice() };
    }

    pub fn prev(self: Self) !Self {
        var out = ArrayList(*dom.Node).init(self.allocator);
        for (self.nodes) |node| {
            const p = node.parent orelse continue;
            for (p.children.items, 0..) |candidate, i| {
                if (candidate == node) {
                    var j = i;
                    while (j > 0) {
                        j -= 1;
                        if (!p.children.items[j].isText()) {
                            try out.append(p.children.items[j]);
                            break;
                        }
                    }
                    break;
                }
            }
        }
        return Self{ .allocator = self.allocator, .nodes = try out.toOwnedSlice() };
    }

    pub fn filter(self: Self, selector: []const u8) !Self {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const chain = try parseChain(arena.allocator(), selector);
        var out = ArrayList(*dom.Node).init(self.allocator);
        for (self.nodes) |node| if (matchesChain(node, chain, null)) try out.append(node);
        return Self{ .allocator = self.allocator, .nodes = try out.toOwnedSlice() };
    }

    pub fn remove(self: Self) void {
        for (self.nodes) |node| {
            if (node.parent) |p| {
                _ = p.removeChild(node);
            }
        }
    }

    pub fn empty(self: Self) void {
        for (self.nodes) |node| node.clearChildren();
    }

    /// `.find(selector)`: descendants of every matched node that match
    /// `selector`, deduplicated in document order of first occurrence.
    pub fn find(self: Self, selector: []const u8) !Self {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const chain = try parseChain(arena.allocator(), selector);

        var out = ArrayList(*dom.Node).init(self.allocator);
        var seen = std.AutoHashMap(*dom.Node, void).init(arena.allocator());
        for (self.nodes) |root| {
            for (root.children.items) |child| {
                var matched = ArrayList(*dom.Node).init(arena.allocator());
                try collectMatches(arena.allocator(), child, chain, &matched, root);
                for (matched.items) |m| {
                    if (!seen.contains(m)) {
                        try seen.put(m, {});
                        try out.append(m);
                    }
                }
            }
        }
        return Self{ .allocator = self.allocator, .nodes = try out.toOwnedSlice() };
    }

    /// `.each(callback)`, matching cheerio's `(index, node) => void` iteration.
    pub fn each(self: Self, comptime callback: fn (usize, *dom.Node) void) void {
        for (self.nodes, 0..) |node, i| callback(i, node);
    }
};

/// The cheerio-style entry point: `$(root, selector)` selects descendants
/// of `root` (root itself included in the search space) matching `selector`.
pub fn select(allocator: mem.Allocator, root: *dom.Node, selector: []const u8) !Selection {
    var wrapper = [_]*dom.Node{root};
    const initial = Selection{ .allocator = allocator, .nodes = wrapper[0..] };
    // Include the root itself in matching, like cheerio's `$(html)` root.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const chain = try parseChain(arena.allocator(), selector);

    var out = ArrayList(*dom.Node).init(allocator);
    var seen = std.AutoHashMap(*dom.Node, void).init(arena.allocator());
    var matched = ArrayList(*dom.Node).init(arena.allocator());
    try collectMatches(arena.allocator(), initial.nodes[0], chain, &matched, null);
    for (matched.items) |m| {
        if (!seen.contains(m)) {
            try seen.put(m, {});
            try out.append(m);
        }
    }
    return Selection{ .allocator = allocator, .nodes = try out.toOwnedSlice() };
}

const dsl = @import("dsl.zig");

test "select matches tag, class, and id" {
    const allocator = std.testing.allocator;
    const spec = comptime dsl.el("div", .{ .id = "app" }, .{
        dsl.el("p", .{ .class = "greeting" }, .{"Hello"}),
        dsl.el("p", .{ .class = "greeting loud" }, .{"World"}),
        dsl.el("span", .{}, .{"ignored"}),
    });
    const root = try dsl.render(allocator, spec);
    defer freeTree(allocator, root);

    var byTag = try select(allocator, root, "p");
    defer byTag.deinit();
    try std.testing.expectEqual(@as(usize, 2), byTag.length());

    var byClass = try select(allocator, root, ".loud");
    defer byClass.deinit();
    try std.testing.expectEqual(@as(usize, 1), byClass.length());
    const t = try byClass.text();
    defer allocator.free(t);
    try std.testing.expectEqualStrings("World", t);

    var byId = try select(allocator, root, "#app");
    defer byId.deinit();
    try std.testing.expectEqual(@as(usize, 1), byId.length());

    var descendant = try select(allocator, root, "div p.greeting");
    defer descendant.deinit();
    try std.testing.expectEqual(@as(usize, 2), descendant.length());
}

test "Selection.find scopes to matched nodes' descendants" {
    const allocator = std.testing.allocator;
    const spec = comptime dsl.el("div", .{}, .{
        dsl.el("section", .{ .id = "a" }, .{
            dsl.el("p", .{}, .{"one"}),
        }),
        dsl.el("section", .{ .id = "b" }, .{
            dsl.el("p", .{}, .{"two"}),
        }),
    });
    const root = try dsl.render(allocator, spec);
    defer freeTree(allocator, root);

    var section = try select(allocator, root, "#a");
    defer section.deinit();
    var p = try section.find("p");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.length());
    const t = try p.text();
    defer allocator.free(t);
    try std.testing.expectEqualStrings("one", t);
}

fn freeTree(allocator: mem.Allocator, node: *dom.Node) void {
    dom.destroyTree(allocator, node);
}


test "find does not use ancestors outside its scope" {
    const allocator = std.testing.allocator;
    const test_dsl = @import("dsl.zig");
    const spec = comptime test_dsl.el("div", .{}, .{
        dsl.el("section", .{}, .{dsl.el("p", .{}, .{"inside"})}),
    });
    const root = try dsl.render(allocator, spec);
    defer dom.destroyTree(allocator, root);

    var section = try select(allocator, root, "section");
    defer section.deinit();
    var result = try section.find("div p");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.length());
}

test "next skips text nodes" {
    const allocator = std.testing.allocator;
    const dsl = @import("dsl.zig");
    const spec = comptime dsl.el("div", .{}, .{
        dsl.el("p", .{}, .{"a"}),
        " between ",
        dsl.el("span", .{}, .{"b"}),
    });
    const root = try dsl.render(allocator, spec);
    defer dom.destroyTree(allocator, root);

    var p = try select(allocator, root, "p");
    defer p.deinit();
    var next_node = try p.next();
    defer next_node.deinit();
    try std.testing.expectEqualStrings("span", next_node.get(0).?.tag);
}
