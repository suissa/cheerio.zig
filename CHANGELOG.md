# Changelog

## Unreleased

Ported the build system and source to Zig 0.16 (new `std.Build` API, value-type
`std.mem.Allocator`, `std.ArrayList` unmanaged-by-default via `std.array_list.Managed`,
`std.Io.Dir`-based file I/O, replaced the removed `std.fifo.LinearFifo` with a small
internal FIFO, updated JSON/builtin renames). Fixed several parser/node compile
errors left over from the in-progress DOM implementation.

## 0.2.0

Updated for Zig 0.10.0

## 0.1.0

Mostly spec compliant HTML parser implementaiton in Zig