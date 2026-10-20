//! mymonitor's symbols: line icons on a 24-unit grid (round strokes in
//! the current color, a few filled shapes), drawn as SVG at any size and
//! color: the parts of the machine, the pages, and the controls.
const myzig = @import("myzig");
const ui = myzig.ui;

pub const Glyph = enum {
    overview,
    processes,
    cpu,
    memory,
    gpu,
    disk,
    network,
    energy,
    apps,
    cleanup,
    laptop,
    monitor,
    battery,
    plug,
    wifi,
    ethernet,
    gear,
    sidebar,
    refresh,
    pause,
    play,
    chevron_right,
    chevron_down,
    chevron_up,
    check,
    search,
    info,
    stop,
    close,
    activity,
    trash,
    download,
    package,
    hammer,
    chat,
    doc,
    clock,
    shield,
    layers,
};

fn svg(comptime body: []const u8) []const u8 {
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\" width=\"24\" height=\"24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\">" ++ body ++ "</svg>";
}

fn source(g: Glyph) []const u8 {
    return switch (g) {
        .overview => svg("<rect x=\"3\" y=\"3\" width=\"7.5\" height=\"7.5\" rx=\"1.6\"/><rect x=\"13.5\" y=\"3\" width=\"7.5\" height=\"7.5\" rx=\"1.6\"/><rect x=\"3\" y=\"13.5\" width=\"7.5\" height=\"7.5\" rx=\"1.6\"/><rect x=\"13.5\" y=\"13.5\" width=\"7.5\" height=\"7.5\" rx=\"1.6\"/>"),
        .processes => svg("<path d=\"M9 6h12M9 12h12M9 18h12\"/><circle cx=\"4\" cy=\"6\" r=\"1.2\" fill=\"currentColor\" stroke=\"none\"/><circle cx=\"4\" cy=\"12\" r=\"1.2\" fill=\"currentColor\" stroke=\"none\"/><circle cx=\"4\" cy=\"18\" r=\"1.2\" fill=\"currentColor\" stroke=\"none\"/>"),
        .cpu => svg("<rect x=\"5\" y=\"5\" width=\"14\" height=\"14\" rx=\"2\"/><rect x=\"9\" y=\"9\" width=\"6\" height=\"6\" rx=\"1\"/><path d=\"M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3\"/>"),
        .memory => svg("<rect x=\"2\" y=\"6\" width=\"20\" height=\"11\" rx=\"2\"/><path d=\"M6.5 10v3M10.5 10v3M14.5 10v3M18 10v3M5 17v3M19 17v3\"/>"),
        .gpu => svg("<rect x=\"2\" y=\"5\" width=\"20\" height=\"13\" rx=\"2.5\"/><circle cx=\"9\" cy=\"11.5\" r=\"3.2\"/><path d=\"M15 9.5h3.5M15 13.5h3.5M5 18v2\"/>"),
        .disk => svg("<rect x=\"3\" y=\"5\" width=\"18\" height=\"14\" rx=\"3\"/><path d=\"M3 13.5h18\"/><circle cx=\"16.5\" cy=\"16.3\" r=\"1\" fill=\"currentColor\" stroke=\"none\"/>"),
        .network => svg("<path d=\"M7.5 20V4M3.5 8l4-4 4 4M16.5 4v16M12.5 16l4 4 4-4\"/>"),
        .energy => svg("<path d=\"M13 2 4.5 13.5H11L10 22l8.5-11.5H12z\"/>"),
        .apps => svg("<rect x=\"3\" y=\"3\" width=\"5\" height=\"5\" rx=\"1.2\"/><rect x=\"9.5\" y=\"3\" width=\"5\" height=\"5\" rx=\"1.2\"/><rect x=\"16\" y=\"3\" width=\"5\" height=\"5\" rx=\"1.2\"/><rect x=\"3\" y=\"9.5\" width=\"5\" height=\"5\" rx=\"1.2\"/><rect x=\"9.5\" y=\"9.5\" width=\"5\" height=\"5\" rx=\"1.2\"/><rect x=\"16\" y=\"9.5\" width=\"5\" height=\"5\" rx=\"1.2\"/><rect x=\"3\" y=\"16\" width=\"5\" height=\"5\" rx=\"1.2\"/><rect x=\"9.5\" y=\"16\" width=\"5\" height=\"5\" rx=\"1.2\"/><rect x=\"16\" y=\"16\" width=\"5\" height=\"5\" rx=\"1.2\"/>"),
        .cleanup => svg("<path d=\"M10 3.5l1.8 4.7 4.7 1.8-4.7 1.8L10 16.5l-1.8-4.7L3.5 10l4.7-1.8z\"/><path d=\"M18 14l.9 2.1 2.1.9-2.1.9L18 20l-.9-2.1L15 17l2.1-.9z\"/>"),
        .laptop => svg("<rect x=\"4\" y=\"5\" width=\"16\" height=\"11\" rx=\"1.5\"/><path d=\"M2 19.5h20\"/>"),
        .monitor => svg("<rect x=\"3\" y=\"4\" width=\"18\" height=\"12\" rx=\"2\"/><path d=\"M8 20h8M12 16v4\"/>"),
        .battery => svg("<rect x=\"2\" y=\"7\" width=\"17\" height=\"10\" rx=\"2.2\"/><path d=\"M22 10.5v3\"/><rect x=\"5\" y=\"10\" width=\"9\" height=\"4\" rx=\"0.8\" fill=\"currentColor\" stroke=\"none\"/>"),
        .plug => svg("<path d=\"M9 2.5v5M15 2.5v5M6 7.5h12v3.5a6 6 0 0 1-12 0zM12 17v4.5\"/>"),
        .wifi => svg("<path d=\"M2.5 9a14 14 0 0 1 19 0M5.5 12.5a9.5 9.5 0 0 1 13 0M8.8 16a5 5 0 0 1 6.4 0\"/><circle cx=\"12\" cy=\"19.3\" r=\"1.2\" fill=\"currentColor\" stroke=\"none\"/>"),
        .ethernet => svg("<rect x=\"3\" y=\"5\" width=\"18\" height=\"12\" rx=\"2\"/><path d=\"M7 9v4M10.5 9v4M14 9v4M17.5 9v4M9 21h6M12 17v4\"/>"),
        .gear => svg("<circle cx=\"12\" cy=\"12\" r=\"3\"/><path d=\"M12 2.5v2.6M12 18.9v2.6M21.5 12h-2.6M5.1 12H2.5M18.7 5.3l-1.8 1.8M7.1 16.9l-1.8 1.8M18.7 18.7l-1.8-1.8M7.1 7.1 5.3 5.3\"/><circle cx=\"12\" cy=\"12\" r=\"7\"/>"),
        .sidebar => svg("<rect x=\"3\" y=\"4\" width=\"18\" height=\"16\" rx=\"2.5\"/><path d=\"M9.5 4v16\"/>"),
        .refresh => svg("<path d=\"M20 12a8 8 0 1 1-2.6-5.9M20 4v5h-5\"/>"),
        .pause => svg("<rect x=\"6.5\" y=\"5\" width=\"3.5\" height=\"14\" rx=\"1\" fill=\"currentColor\" stroke=\"none\"/><rect x=\"14\" y=\"5\" width=\"3.5\" height=\"14\" rx=\"1\" fill=\"currentColor\" stroke=\"none\"/>"),
        .play => svg("<path d=\"M7 4.5l12.5 7.5L7 19.5z\" fill=\"currentColor\"/>"),
        .chevron_right => svg("<path d=\"M9 5.5l6.5 6.5L9 18.5\"/>"),
        .chevron_down => svg("<path d=\"M5.5 9l6.5 6.5L18.5 9\"/>"),
        .chevron_up => svg("<path d=\"M5.5 15l6.5-6.5 6.5 6.5\"/>"),
        .check => svg("<path d=\"M4.5 12.5l5 5 10-11\"/>"),
        .search => svg("<circle cx=\"10.5\" cy=\"10.5\" r=\"6.5\"/><path d=\"M20 20l-4.8-4.8\"/>"),
        .info => svg("<circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"M12 11v6\"/><circle cx=\"12\" cy=\"7.6\" r=\"1.1\" fill=\"currentColor\" stroke=\"none\"/>"),
        .stop => svg("<circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"M9 9l6 6M15 9l-6 6\"/>"),
        .close => svg("<path d=\"M6 6l12 12M18 6 6 18\"/>"),
        .activity => svg("<path d=\"M2 12h4l3-8 6 16 3-8h4\"/>"),
        .trash => svg("<path d=\"M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3\"/>"),
        .download => svg("<path d=\"M12 3v12M7 10l5 5 5-5M5 20.5h14\"/>"),
        .package => svg("<path d=\"M21 8l-9-5-9 5 9 5zM3 8v8.5l9 5 9-5V8M12 13v8.5\"/>"),
        .hammer => svg("<path d=\"M13 7l4 4M3 21l9.5-9.5M11 5l3-3 8 8-3 3z\"/>"),
        .chat => svg("<path d=\"M4 4.5h16v11.5H9.5L4 20.5z\"/>"),
        .doc => svg("<path d=\"M6 2.5h8.5L19 7v14.5H6zM14 2.5V7h5M9 12h7M9 16h7\"/>"),
        .clock => svg("<circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"M12 7v5.5l3.5 2\"/>"),
        .shield => svg("<path d=\"M12 2.5l8 3v6c0 5-3.5 8.5-8 10-4.5-1.5-8-5-8-10v-6z\"/><path d=\"M8.5 12l2.5 2.5 4.5-5\"/>"),
        .layers => svg("<path d=\"M12 3l9 5-9 5-9-5zM3 13l9 5 9-5\"/>"),
    };
}

/// Draws `g`, `size` points square, in `color`.
pub fn glyph(c: *ui.Context, g: Glyph, size: f32, color: ui.Color) void {
    _ = ui.svg(c, source(g), .{ .width = size, .height = size, .color = color });
}

test "every glyph is an SVG document" {
    const std = @import("std");
    for (std.enums.values(Glyph)) |g| try std.testing.expect(std.mem.startsWith(u8, source(g), "<svg"));
}
