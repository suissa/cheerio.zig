const std = @import("std");
const mem = std.mem;
const dom = @import("dom.zig");

/// A comptime-only, allocation-free description of an element tree. Built up
/// with `el`/`text` calls nested inside comptime-known struct literals, then
/// turned into a real `dom.Node` tree with `render`. This is the "comptime
/// DSL" half of the cheerio-style API: a type-checked, zero-cost way to
/// author markup, mirroring how cheerio lets you build up a document before
/// querying it with `$`.
pub const NodeSpec = struct {
    tag: []const u8,
    attrs: []const Attr = &.{},
    children: []const NodeSpec = &.{},
    text: ?[]const u8 = null,
};

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

/// Builds a `NodeSpec` for a text node. Mirrors cheerio's implicit text
/// nodes when you pass a string as a child.
pub fn text(comptime value: []const u8) NodeSpec {
    return .{ .tag = "#text", .text = value };
}

/// Builds a `NodeSpec` for an element.
///
/// `attrs` is a comptime struct literal, e.g. `.{ .id = "app", .class = "row" }`.
/// `children` is a comptime tuple whose entries are either `NodeSpec`
/// (from nested `el`/`text` calls) or `[]const u8` (a bare string, treated
/// like a text child, same as passing a string straight to `text`).
///
/// Example, mirroring cheerio's fluent construction:
/// ```zig
/// const spec = el("div", .{ .class = "greeting" }, .{
///     el("strong", .{}, .{"Hello, "}),
///     "world!",
/// });
/// ```
pub fn el(comptime tag: []const u8, comptime attrs: anytype, comptime children: anytype) NodeSpec {
    const attrs_info = @typeInfo(@TypeOf(attrs)).@"struct";
    comptime var built_attrs: [attrs_info.fields.len]Attr = undefined;
    inline for (attrs_info.fields, 0..) |field, i| {
        built_attrs[i] = .{ .name = field.name, .value = @field(attrs, field.name) };
    }

    const children_info = @typeInfo(@TypeOf(children)).@"struct";
    comptime var built_children: [children_info.fields.len]NodeSpec = undefined;
    inline for (children_info.fields, 0..) |field, i| {
        const child = @field(children, field.name);
        built_children[i] = switch (@TypeOf(child)) {
            NodeSpec => child,
            else => text(child),
        };
    }

    const final_attrs = built_attrs;
    const final_children = built_children;
    return .{ .tag = tag, .attrs = &final_attrs, .children = &final_children };
}

/// Materializes a comptime `NodeSpec` tree into a real, allocator-owned
/// `dom.Node` tree that can then be queried with `select.Selection`.
pub fn render(allocator: mem.Allocator, comptime spec: NodeSpec) !*dom.Node {
    const node = dom.Node.init(allocator, spec.tag);
    if (spec.text) |t| node.text = t;
    inline for (spec.attrs) |a| {
        try node.attrs.put(a.name, a.value);
    }
    inline for (spec.children) |child_spec| {
        const child = try render(allocator, child_spec);
        node.appendChild(child);
    }
    return node;
}

test "el/render builds a tree matching the spec" {
    const allocator = std.testing.allocator;

    const spec = comptime el("div", .{ .class = "greeting", .id = "hi" }, .{
        el("strong", .{}, .{"Hello, "}),
        "world!",
    });

    const root = try render(allocator, spec);
    defer dom.Node.destroyTree(allocator, root);

    try std.testing.expectEqualStrings("div", root.tag);
    try std.testing.expectEqualStrings("greeting", root.attr("class").?);
    try std.testing.expectEqualStrings("hi", root.attr("id").?);
    try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
    try std.testing.expectEqualStrings("strong", root.children.items[0].tag);

    const full_text = try root.textContent(allocator);
    defer allocator.free(full_text);
    try std.testing.expectEqualStrings("Hello, world!", full_text);
}

