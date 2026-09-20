const std = @import("std");
const mem = std.mem;
const ArrayList = std.array_list.Managed;
const dom = @import("dom.zig");

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
            if (!mem.eql(u8, t, "*") and !mem.eql(u8, t, node.tag)) return false;
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
fn matchesChain(node: *const dom.Node, chain: []const Compound) bool {
    if (chain.len == 0) return true;
    if (!chain[chain.len - 1].matches(node)) return false;

    var remaining = chain[0 .. chain.len - 1];
    var ancestor = node.parent;
    while (remaining.len > 0) {
        const current = ancestor orelse return false;
        if (remaining[remaining.len - 1].matches(current)) {
            remaining = remaining[0 .. remaining.len - 1];
        }
        ancestor = current.parent;
    }
    return true;
}

fn collectMatches(allocator: mem.Allocator, node: *dom.Node, chain: []const Compound, out: *ArrayList(*dom.Node)) !void {
    if (matchesChain(node, chain)) try out.append(node);
    for (node.children.items) |child| {
        try collectMatches(allocator, child, chain, out);
    }
}

/// The comptime-computed return type of `Selection.text`: a plain string
/// when called as a getter (`.text(.{})`), or `Selection` (for chaining)
/// when called as a setter (`.text(.{value})`).
fn TextReturn(comptime ArgsT: type) type {
    return if (@typeInfo(ArgsT).@"struct".fields.len == 0) anyerror![]const u8 else Selection;
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

    /// `.text()` / `.text(value)`: cheerio-style getter/setter overloaded on
    /// argument count via a comptime tuple, since Zig has no true function
    /// overloading. Call as `sel.text(.{})` to read, `sel.text(.{"new text"})`
    /// to write (mutates every matched node and returns `self` for chaining,
    /// just like jQuery/cheerio's `.text(value)`).
    pub fn text(self: Self, args: anytype) TextReturn(@TypeOf(args)) {
        const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
        if (fields.len == 0) {
            return self.getText();
        } else {
            const value: []const u8 = args[0];
            for (self.nodes) |node| node.setText(self.allocator, value) catch {};
            return self;
        }
    }

    /// The getter half of `.text()`, also usable directly.
    pub fn getText(self: Self) ![]const u8 {
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

    /// `.addClass(name)`: adds `name` to every matched node's class list.
    /// Returns `self` for chaining, matching cheerio's `.addClass()`.
    pub fn addClass(self: Self, class: []const u8) Self {
        for (self.nodes) |node| node.addClass(self.allocator, class) catch {};
        return self;
    }

    /// `.removeClass(name)`: removes `name` from every matched node's class
    /// list. Returns `self` for chaining.
    pub fn removeClass(self: Self, class: []const u8) Self {
        for (self.nodes) |node| node.removeClass(self.allocator, class) catch {};
        return self;
    }

    /// `.html()`: the serialized outer HTML of the first matched node.
    pub fn html(self: Self) !?[]const u8 {
        if (self.nodes.len == 0) return null;
        return try self.nodes[0].outerHtml(self.allocator);
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
                try collectMatches(arena.allocator(), child, chain, &matched);
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
    /// Inside the callback, wrap `node` with `$(node)` (or `select.fromNode`)
    /// to get a `Selection` for chained cheerio-style calls on that element.
    pub fn each(self: Self, comptime callback: fn (usize, *dom.Node) void) void {
        for (self.nodes, 0..) |node, i| callback(i, node);
    }

    /// Wraps a single, already-known node in a one-element `Selection`,
    /// matching cheerio's `$(el)` re-wrap of a raw element (e.g. inside
    /// `.each((i, el) => $(el).text())`).
    pub fn fromNode(allocator: mem.Allocator, node: *dom.Node) Selection {
        const out = allocator.alloc(*dom.Node, 1) catch return Selection{ .allocator = allocator, .nodes = &.{} };
        out[0] = node;
        return Selection{ .allocator = allocator, .nodes = out };
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
    try collectMatches(arena.allocator(), initial.nodes[0], chain, &matched);
    for (matched.items) |m| {
        if (!seen.contains(m)) {
            try seen.put(m, {});
            try out.append(m);
        }
    }
    return Selection{ .allocator = allocator, .nodes = try out.toOwnedSlice() };
}

/// The "loaded document" that `$` (see below) queries against, mirroring
/// what `const $ = cheerio.load(html)` closes over in JS. Zig has no
/// closures that capture runtime state into a free function, so instead
/// `load` stashes the document here and the free function `@"$"` reads it
/// back — the same one-document-at-a-time tradeoff `libxml2`/BeautifulSoup-
/// style module-level APIs make. For multiple concurrent documents, use
/// `select`/`Selection.fromNode` directly instead of `$`.
const Doc = struct {
    allocator: mem.Allocator,
    root: *dom.Node,
};
var current_doc: ?Doc = null;

/// Sets the document that bare `$(...)` calls operate against, matching
/// cheerio's `const $ = cheerio.load(html)`. `root` is typically built with
/// `dsl.render`.
pub fn load(allocator: mem.Allocator, root: *dom.Node) void {
    current_doc = Doc{ .allocator = allocator, .root = root };
}

/// The cheerio-style `$(...)` entry point. Call `load()` first.
///
/// - `$(selector: []const u8)`: selects descendants (and the root itself)
///   of the loaded document matching the CSS selector, e.g. `$("h2.title")`.
/// - `$(node: *dom.Node)`: re-wraps an already-known node in a `Selection`,
///   e.g. `$(el)` inside an `.each((i, el) => ...)` callback.
///
/// Errors are swallowed into an empty `Selection` (mirroring cheerio's
/// exception-free chaining); use `select`/`Selection.fromNode` directly if
/// you need to observe them.
pub fn @"$"(arg: anytype) Selection {
    const doc = current_doc orelse @panic("zhtml.load(allocator, root) must be called before using $");
    if (@TypeOf(arg) == *dom.Node) {
        return Selection.fromNode(doc.allocator, arg);
    }
    const selector: []const u8 = arg;
    return select(doc.allocator, doc.root, selector) catch Selection{ .allocator = doc.allocator, .nodes = &.{} };
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
    defer dom.Node.destroyTree(allocator, root);

    var byTag = try select(allocator, root, "p");
    defer byTag.deinit();
    try std.testing.expectEqual(@as(usize, 2), byTag.length());

    var byClass = try select(allocator, root, ".loud");
    defer byClass.deinit();
    try std.testing.expectEqual(@as(usize, 1), byClass.length());
    const t = try byClass.text(.{});
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
    defer dom.Node.destroyTree(allocator, root);

    var section = try select(allocator, root, "#a");
    defer section.deinit();
    var p = try section.find("p");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.length());
    const t = try p.text(.{});
    defer allocator.free(t);
    try std.testing.expectEqualStrings("one", t);
}

test "Selection.text(.{value}) sets text and returns self for chaining" {
    const allocator = std.testing.allocator;
    const spec = comptime dsl.el("h2", .{ .class = "title" }, .{"old"});
    const root = try dsl.render(allocator, spec);
    defer dom.Node.destroyTree(allocator, root);

    var h2 = try select(allocator, root, "h2.title");
    defer h2.deinit();
    _ = h2.text(.{"Hello there!"});

    const t = try h2.text(.{});
    defer allocator.free(t);
    try std.testing.expectEqualStrings("Hello there!", t);
}

test "Selection.addClass / removeClass" {
    // addClass/removeClass allocate new attribute values; use an arena
    // rather than fighting the leak checker over an intentional
    // free-the-whole-tree-at-once ownership model (see dom.zig's note).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const spec = comptime dsl.el("h2", .{}, .{"hi"});
    const root = try dsl.render(allocator, spec);

    var h2 = try select(allocator, root, "h2");
    defer h2.deinit();
    _ = h2.addClass("welcome");
    try std.testing.expect(root.hasClass("welcome"));
    _ = h2.removeClass("welcome");
    try std.testing.expect(!root.hasClass("welcome"));
}

test "$(selector) and $(el) inside .each, cheerio-style" {
    const allocator = std.testing.allocator;
    const spec = comptime dsl.el("div", .{}, .{
        dsl.el("a", .{ .href = "/one" }, .{"One"}),
        dsl.el("a", .{ .href = "/two" }, .{"Two"}),
    });
    const root = try dsl.render(allocator, spec);
    defer dom.Node.destroyTree(allocator, root);

    load(allocator, root);
    var links = @"$"("a");
    defer links.deinit();
    try std.testing.expectEqual(@as(usize, 2), links.length());

    links.each(struct {
        fn call(i: usize, el: *dom.Node) void {
            var wrapped = @"$"(el);
            defer wrapped.deinit();
            const t = wrapped.getText() catch unreachable;
            defer std.testing.allocator.free(t);
            if (i == 0) {
                std.testing.expectEqualStrings("One", t) catch unreachable;
                std.testing.expectEqualStrings("/one", wrapped.attr("href").?) catch unreachable;
            } else {
                std.testing.expectEqualStrings("Two", t) catch unreachable;
            }
        }
    }.call);

    var title = @"$"("h2.title"); // no h2 in this tree: matches empty, not an error
    defer title.deinit();
    try std.testing.expectEqual(@as(usize, 0), title.length());
}

