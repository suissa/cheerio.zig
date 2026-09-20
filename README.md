# Z-HTML

This is a work in progress, spec compliant, HTML parser built with [Zig](https://ziglang.org). Currently lots of things are broken. You can check the status of tests that _are not_ passing by checking out the `ignored_tests` in [test/tokenizer-html5lib.zig](test/tokenizer-html5lib.zig).

## Roadmap

- [x] Tokenizer (missing a few edge cases)
- [ ] Parser (in progress)
- [ ] JavaScript DOM API support
- [x] cheerio-style comptime DSL + CSS selector query API (`dsl`/`select`)

See the [CHANGELOG.md](changelog) for detailed information on past changes.

## Building

Requires Zig 0.16.0.

```sh
zig build test           # run the library's unit tests
zig build test-html5lib  # run the tokenizer against the html5lib-tests suite
```

## Tokenizer

The `Tokenizer` struct provides a (mostly) fully featured HTML tokenizer built according to the [WHATGW HTML Spec](https://html.spec.whatwg.org/multipage/parsing.html#tokenization). It is a streaming tokenizer which takes as input a full document, processes the document character by character, and emits both `Token`s and `ParseError`s. An example usage of it by itself could look like this:

```zig
const std = @import("std");
const zhtml = @import("zhtml");
const Token = zhtml.Token;
const Tokenizer = zhtml.Tokenizer;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var tokenizer = try Tokenizer.initWithString(allocator, "<p>Hello, world!</p>");
    while (true) {
        const token = tokenizer.nextToken() catch |err| {
            std.debug.print("{} (line: {}, column: {})\n", .{ err, tokenizer.line, tokenizer.column });
            continue;
        };

        switch (token) {
            .EndOfFile => break,
            else => std.debug.print("{}\n", .{token}),
        }
    }
}
```

though the `Tokenizer` is meant to be used in conjunction with the `Parser`.

## Parser

Work in progress. Check back later.

## The cheerio-style DSL

Independent of the spec tokenizer/parser above, `zhtml.dsl` and `zhtml.select`
provide a small, comptime-checked way to build a tree and query it the way
you'd use [cheerio](https://cheerio.js.org/)'s `$`:

```zig
const std = @import("std");
const zhtml = @import("zhtml");
const el = zhtml.dsl.el;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Build the tree at comptime, type-checked as you write it.
    const spec = comptime el("div", .{ .id = "app" }, .{
        el("p", .{ .class = "greeting" }, .{"Hello, "}),
        el("p", .{ .class = "greeting loud" }, .{"world!"}),
    });
    const root = try zhtml.dsl.render(allocator, spec);

    // Query it like cheerio's `$(html)`.
    var loud = try zhtml.select(allocator, root, ".loud");
    defer loud.deinit();
    const message = try loud.text();
    defer allocator.free(message);
    std.debug.print("{s}\n", .{message}); // "world!"
}
```

`Selection` supports the common chainable cheerio methods: `.find(selector)`,
`.text()`, `.attr(name)`, `.html()`, `.first()`, `.eq(index)`, and `.each(fn)`.
Selectors support tag names, `.class`, `#id`, `*`, compound selectors
(`div.row#main`), and descendant combinators (`div p.item`).

## License

Copyright 2022 Chris Watson

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
