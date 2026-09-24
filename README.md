# zcrawl

A Zig 0.16 HTML parser and cheerio-style query API.

The public package/module name is `zcrawl`.

## Install

From your Zig project:

```sh
zig fetch --save git+https://github.com/suissa/cheerio.zig
```

Because this repository now ships a Zig package manifest with `.name = .zcrawl`,
Zig can add it to your project's `build.zig.zon`.

Then wire the dependency into your `build.zig`:

```zig
const zcrawl_dep = b.dependency("zcrawl", .{
    .target = target,
    .optimize = optimize,
});

const exe = b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "zcrawl",
                .module = zcrawl_dep.module("zcrawl"),
            },
        },
    }),
});
```

And import it in Zig:

```zig
const zcrawl = @import("zcrawl");
```

## HTML loading and selectors

```zig
const std = @import("std");
const zcrawl = @import("zcrawl");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var page = try zcrawl.load(
        allocator,
        "<main><h1>Hello</h1><p class=\"item\">World</p></main>",
    );
    defer page.deinit();

    var heading = try page.select("main h1");
    defer heading.deinit();

    const title = try heading.text();
    defer allocator.free(title);

    std.debug.print("{s}\n", .{title});
}
```

`Selection` supports the common cheerio-style methods:

- `.find(selector)`
- `.text()`
- `.attr(name)`
- `.html()`
- `.first()`
- `.eq(index)`
- `.each(fn)`

Selectors support tag names, `.class`, `#id`, `*`, compound selectors such as
`div.row#main`, and descendant combinators.

## DSL

```zig
const std = @import("std");
const zcrawl = @import("zcrawl");
const el = zcrawl.dsl.el;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const spec = comptime el("div", .{ .id = "app" }, .{
        el("p", .{ .class = "greeting" }, .{"Hello, "}),
        el("p", .{ .class = "greeting loud" }, .{"world!"}),
    });

    const root = try zcrawl.dsl.render(allocator, spec);

    var loud = try zcrawl.select(allocator, root, ".loud");
    defer loud.deinit();

    const message = try loud.text();
    defer allocator.free(message);

    std.debug.print("{s}\n", .{message});
}
```

## Tokenizer

```zig
const std = @import("std");
const zcrawl = @import("zcrawl");

const Token = zcrawl.Token;
const Tokenizer = zcrawl.Tokenizer;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var tokenizer = try Tokenizer.initWithString(
        allocator,
        "<p>Hello, world!</p>",
    );

    while (true) {
        const token = tokenizer.nextToken() catch |err| {
            std.debug.print(
                "{} (line: {}, column: {})\n",
                .{ err, tokenizer.line, tokenizer.column },
            );
            continue;
        };

        switch (token) {
            .EndOfFile => break,
            else => std.debug.print("{}\n", .{token}),
        }
    }
}
```

## Building

Requires Zig 0.16.0.

```sh
zig build test
```

The html5lib tokenizer fixtures are a Git submodule. For the html5lib suite, clone
with `--recurse-submodules` or run:

```sh
git submodule update --init
zig build test-html5lib
```

## License

MIT.
