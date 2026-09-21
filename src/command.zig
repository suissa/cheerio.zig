const std = @import("std");
const mem = std.mem;
const ArrayList = std.array_list.Managed;

pub const CommandParseError = error{
    EmptyCommand,
    UnexpectedEndOfCommand,
    UnknownCommand,
    ExpectedKeyword,
    ExpectedString,
    ExpectedIdentifier,
    ExpectedSymbol,
    InvalidIdentifier,
    InvalidEscape,
    TrailingInput,
};

pub const Command = union(enum) {
    Load: struct {
        html: []const u8,
    },
    GetText: struct {
        selector: []const u8,
        alias: ?[]const u8 = null,
    },
    Select: struct {
        selector: []const u8,
        alias: []const u8,
    },
    Type: struct {
        value: []const u8,
        alias: []const u8,
    },
    Click: struct {
        selector: []const u8,
    },
    Return: struct {
        fields: [][]const u8,
    },
};

pub const Script = struct {
    allocator: mem.Allocator,
    commands: []Command,

    pub fn deinit(self: *Script) void {
        for (self.commands) |command| freeCommand(self.allocator, command);
        self.allocator.free(self.commands);
        self.commands = &.{};
    }

    pub fn len(self: Script) usize {
        return self.commands.len;
    }
};

pub fn parse(allocator: mem.Allocator, source: []const u8) !Script {
    var commands = ArrayList(Command).init(allocator);
    errdefer {
        for (commands.items) |command| freeCommand(allocator, command);
        commands.deinit();
    }

    var lines = mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        var cursor = Cursor{ .input = line };
        const keyword = try cursor.word();

        if (mem.eql(u8, keyword, "load")) {
            const html = try cursor.quoted(allocator);
            try cursor.end();
            try appendCommand(allocator, &commands, .{ .Load = .{ .html = html } });
        } else if (mem.eql(u8, keyword, "get")) {
            try cursor.keyword("text");
            try cursor.keyword("from");
            const selector = try cursor.quoted(allocator);
            try cursor.end();
            try appendCommand(allocator, &commands, .{ .GetText = .{ .selector = selector } });
        } else if (mem.eql(u8, keyword, "select")) {
            const selector = try cursor.quoted(allocator);
            try cursor.keyword("to");
            const alias = try cursor.identifier(allocator);
            try cursor.end();
            try appendCommand(allocator, &commands, .{ .Select = .{ .selector = selector, .alias = alias } });
        } else if (mem.eql(u8, keyword, "type")) {
            const value = try cursor.quoted(allocator);
            try cursor.keyword("in");
            const alias = try cursor.identifier(allocator);
            try cursor.end();
            try appendCommand(allocator, &commands, .{ .Type = .{ .value = value, .alias = alias } });
        } else if (mem.eql(u8, keyword, "click")) {
            try cursor.keyword("in");
            const selector = try cursor.quoted(allocator);
            try cursor.end();
            try appendCommand(allocator, &commands, .{ .Click = .{ .selector = selector } });
        } else if (mem.eql(u8, keyword, "return")) {
            const fields = try cursor.objectFields(allocator);
            try cursor.end();
            try appendCommand(allocator, &commands, .{ .Return = .{ .fields = fields } });
        } else if (isIdentifier(keyword)) {
            const alias = try allocator.dupe(u8, keyword);
            errdefer allocator.free(alias);

            try cursor.symbol('=');
            try cursor.keyword("get");
            try cursor.keyword("text");
            try cursor.keyword("from");
            const selector = try cursor.angleSelector(allocator);
            try cursor.end();

            try appendCommand(allocator, &commands, .{
                .GetText = .{
                    .selector = selector,
                    .alias = alias,
                },
            });
        } else {
            return error.UnknownCommand;
        }
    }

    return .{
        .allocator = allocator,
        .commands = try commands.toOwnedSlice(),
    };
}

fn appendCommand(allocator: mem.Allocator, commands: *ArrayList(Command), command: Command) !void {
    commands.append(command) catch |err| {
        freeCommand(allocator, command);
        return err;
    };
}

fn freeCommand(allocator: mem.Allocator, command: Command) void {
    switch (command) {
        .Load => |value| allocator.free(value.html),
        .GetText => |value| {
            allocator.free(value.selector);
            if (value.alias) |alias| allocator.free(alias);
        },
        .Select => |value| {
            allocator.free(value.selector);
            allocator.free(value.alias);
        },
        .Type => |value| {
            allocator.free(value.value);
            allocator.free(value.alias);
        },
        .Click => |value| allocator.free(value.selector),
        .Return => |value| {
            for (value.fields) |field| allocator.free(field);
            allocator.free(value.fields);
        },
    }
}

const Cursor = struct {
    input: []const u8,
    pos: usize = 0,

    fn skipSpace(self: *Cursor) void {
        while (self.pos < self.input.len and isSpace(self.input[self.pos])) self.pos += 1;
    }

    fn word(self: *Cursor) ![]const u8 {
        self.skipSpace();
        if (self.pos >= self.input.len) return error.UnexpectedEndOfCommand;
        if (self.input[self.pos] == '"' or self.input[self.pos] == '<') return error.ExpectedKeyword;

        const start = self.pos;
        while (self.pos < self.input.len and !isSpace(self.input[self.pos])) self.pos += 1;
        return self.input[start..self.pos];
    }

    fn keyword(self: *Cursor, expected: []const u8) !void {
        const actual = try self.word();
        if (!mem.eql(u8, actual, expected)) return error.ExpectedKeyword;
    }

    fn identifier(self: *Cursor, allocator: mem.Allocator) ![]const u8 {
        const value = try self.word();
        if (!isIdentifier(value)) return error.InvalidIdentifier;
        return try allocator.dupe(u8, value);
    }

    fn quoted(self: *Cursor, allocator: mem.Allocator) ![]const u8 {
        self.skipSpace();
        if (self.pos >= self.input.len) return error.ExpectedString;
        if (self.input[self.pos] != '"') return error.ExpectedString;
        self.pos += 1;

        var value = ArrayList(u8).init(allocator);
        errdefer value.deinit();

        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            self.pos += 1;

            if (c == '"') return value.toOwnedSlice();

            if (c != '\\') {
                try value.append(c);
                continue;
            }

            if (self.pos >= self.input.len) return error.UnexpectedEndOfCommand;
            const escaped = self.input[self.pos];
            self.pos += 1;
            switch (escaped) {
                '"' => try value.append('"'),
                '\\' => try value.append('\\'),
                'n' => try value.append('\n'),
                'r' => try value.append('\r'),
                't' => try value.append('\t'),
                else => return error.InvalidEscape,
            }
        }

        return error.UnexpectedEndOfCommand;
    }

    fn angleSelector(self: *Cursor, allocator: mem.Allocator) ![]const u8 {
        self.skipSpace();
        if (self.pos >= self.input.len or self.input[self.pos] != '<') return error.ExpectedSymbol;
        self.pos += 1;

        var value = ArrayList(u8).init(allocator);
        errdefer value.deinit();
        var quote: ?u8 = null;

        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            self.pos += 1;

            if (quote) |active_quote| {
                try value.append(c);
                if (c == active_quote) quote = null;
                continue;
            }

            if (c == '"' or c == '\'') {
                quote = c;
                try value.append(c);
            } else if (c == '>') {
                return value.toOwnedSlice();
            } else {
                try value.append(c);
            }
        }

        return error.UnexpectedEndOfCommand;
    }

    fn objectFields(self: *Cursor, allocator: mem.Allocator) ![][]const u8 {
        self.symbol('{') catch return error.ExpectedSymbol;

        var fields = ArrayList([]const u8).init(allocator);
        errdefer {
            for (fields.items) |field| allocator.free(field);
            fields.deinit();
        }

        while (true) {
            self.skipSpace();
            if (self.pos >= self.input.len) return error.UnexpectedEndOfCommand;
            if (self.input[self.pos] == '}') {
                self.pos += 1;
                break;
            }

            const field = try self.identifier(allocator);
            try fields.append(field);

            self.skipSpace();
            if (self.pos < self.input.len and self.input[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            if (self.pos < self.input.len and self.input[self.pos] == '}') {
                self.pos += 1;
                break;
            }
            return error.ExpectedSymbol;
        }

        return fields.toOwnedSlice();
    }

    fn symbol(self: *Cursor, expected: u8) !void {
        self.skipSpace();
        if (self.pos >= self.input.len or self.input[self.pos] != expected) return error.ExpectedSymbol;
        self.pos += 1;
    }

    fn end(self: *Cursor) !void {
        self.skipSpace();
        if (self.pos != self.input.len) return error.TrailingInput;
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

fn isIdentifier(value: []const u8) bool {
    if (value.len == 0) return false;
    if (!isIdentifierStart(value[0])) return false;
    for (value[1..]) |c| {
        if (!isIdentifierContinue(c)) return false;
    }
    return true;
}

fn isIdentifierStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentifierContinue(c: u8) bool {
    return isIdentifierStart(c) or (c >= '0' and c <= '9') or c == '-';
}

test "parse natural command script" {
    const allocator = std.testing.allocator;
    var script = try parse(allocator,
        "load \"<html><body></body></html>\"\n" ++
        "get text from \"a#password\"\n" ++
        "select \"input[type=email]\" to email\n" ++
        "type \"jaja@ksdl.com\" in email\n" ++
        "click in \"button.submit\"\n",
    );
    defer script.deinit();

    try std.testing.expectEqual(@as(usize, 5), script.len());
    try std.testing.expectEqualStrings("<html><body></body></html>", script.commands[0].Load.html);
    try std.testing.expectEqualStrings("a#password", script.commands[1].GetText.selector);
    try std.testing.expectEqualStrings("input[type=email]", script.commands[2].Select.selector);
    try std.testing.expectEqualStrings("email", script.commands[2].Select.alias);
    try std.testing.expectEqualStrings("jaja@ksdl.com", script.commands[3].Type.value);
    try std.testing.expectEqualStrings("button.submit", script.commands[4].Click.selector);
}

test "parse SemanticBehavior property assignment and return object" {
    const allocator = std.testing.allocator;
    var script = try parse(allocator,
        "street = get text from <span[itemprop=\"streetAddress\"]>\n" ++
        "neighborhood = get text from <body > div.container > div.row.table-responsive > table > tbody > tr:nth-child(2) > td:nth-child(3)>\n" ++
        "locality = get text from <span[itemprop=addressLocality]>\n" ++
        "return { street, neighborhood, locality }\n",
    );
    defer script.deinit();

    try std.testing.expectEqual(@as(usize, 4), script.len());

    try std.testing.expectEqualStrings("street", script.commands[0].GetText.alias.?);
    try std.testing.expectEqualStrings("span[itemprop=\"streetAddress\"]", script.commands[0].GetText.selector);
    try std.testing.expectEqualStrings("neighborhood", script.commands[1].GetText.alias.?);
    try std.testing.expectEqualStrings("body > div.container > div.row.table-responsive > table > tbody > tr:nth-child(2) > td:nth-child(3)", script.commands[1].GetText.selector);
    try std.testing.expectEqualStrings("locality", script.commands[2].GetText.alias.?);
    try std.testing.expectEqualStrings("span[itemprop=addressLocality]", script.commands[2].GetText.selector);

    const result = script.commands[3].Return;
    try std.testing.expectEqual(@as(usize, 3), result.fields.len);
    try std.testing.expectEqualStrings("street", result.fields[0]);
    try std.testing.expectEqualStrings("neighborhood", result.fields[1]);
    try std.testing.expectEqualStrings("locality", result.fields[2]);
}

test "quoted strings support escapes and comments" {
    var script = try parse(std.testing.allocator,
        "# comment\n" ++
        "type \"hello \\\"world\\\"\\n\" in field\n",
    );
    defer script.deinit();

    try std.testing.expectEqual(@as(usize, 1), script.len());
    try std.testing.expectEqualStrings("hello \"world\"\n", script.commands[0].Type.value);
}

test "unknown command is rejected" {
    try std.testing.expectError(error.ExpectedSymbol, parse(std.testing.allocator, "submit \"button\""));
}
