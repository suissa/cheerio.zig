const std = @import("std");
const zhtml = @import("zhtml");

test "SemanticBehavior e2e: CEP extraction contract" {
    const allocator = std.testing.allocator;
    var script = try zhtml.parseCommands(allocator,
        "street = get text from <span[itemprop=\"streetAddress\"]>\n" ++
        "neighborhood = get text from <body > div.container > div.row.table-responsive > table > tbody > tr:nth-child(2) > td:nth-child(3)>\n" ++
        "locality = get text from <span[itemprop=addressLocality]>\n" ++
        "return { street, neighborhood, locality }\n",
    );
    defer script.deinit();

    try std.testing.expectEqual(@as(usize, 4), script.len());

    const street = script.commands[0].GetText;
    try std.testing.expectEqualStrings("street", street.alias.?);
    try std.testing.expectEqualStrings("span[itemprop=\"streetAddress\"]", street.selector);

    const neighborhood = script.commands[1].GetText;
    try std.testing.expectEqualStrings("neighborhood", neighborhood.alias.?);
    try std.testing.expectEqualStrings(
        "body > div.container > div.row.table-responsive > table > tbody > tr:nth-child(2) > td:nth-child(3)",
        neighborhood.selector,
    );

    const locality = script.commands[2].GetText;
    try std.testing.expectEqualStrings("locality", locality.alias.?);
    try std.testing.expectEqualStrings("span[itemprop=addressLocality]", locality.selector);

    const result = script.commands[3].Return;
    try std.testing.expectEqual(@as(usize, 3), result.fields.len);
    try std.testing.expectEqualStrings("street", result.fields[0]);
    try std.testing.expectEqualStrings("neighborhood", result.fields[1]);
    try std.testing.expectEqualStrings("locality", result.fields[2]);
}
