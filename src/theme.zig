//! mymonitor's colors, as Windows 11's own apps have them: a light gray
//! sidebar and white page (or their dark twins), soft gray cards, the
//! system's blue for what is chosen, and a color for each part of the
//! machine (CPU blue, memory green, GPU rose, disk orange, network teal,
//! energy amber); Segoe UI for words, light or dark as the system is.
const builtin = @import("builtin");
const myzig = @import("myzig");
const Color = myzig.ui.Color;

pub const Colors = struct {
    sidebar: Color,
    /// The selected sidebar item, and the text on it.
    picked: Color,
    on_picked: Color,
    page: Color,
    card: Color,
    /// Cards' and wells' edges.
    border: Color,
    /// The well a graph sits in, and a cell with nothing in it.
    well: Color,
    empty: Color,
    separator: Color,
    text: Color,
    secondary: Color,
    tertiary: Color,
    accent: Color,
    /// Table rows: every other one, the selection, the ones marked.
    stripe: Color,
    selection: Color,
    on_selection: Color,
    marked: Color,
    control: Color,
    control_on: Color,
    hover: Color,
    /// The graphs' series.
    user: Color,
    system: Color,
    fast: Color,
    frugal: Color,
    // Parts of the machine.
    gray: Color,
    blue: Color,
    green: Color,
    red: Color,
    orange: Color,
    teal: Color,
    purple: Color,
    yellow: Color,
    /// Light blue: compressed memory, reads, uploads.
    sky: Color,
    /// A row's % CPU when the process is busy, and very busy.
    warm: Color,
    hot: Color,
};

const white: Color = .{ .r = 1, .g = 1, .b = 1 };
const black: Color = .{};

pub fn colors(dark: bool) Colors {
    if (dark) {
        const bg = Color.hex(0x1c1c1c);
        const blue = Color.hex(0x3b8eea);
        return .{
            .sidebar = .hex(0x202020),
            .picked = blue,
            .on_picked = white,
            .page = bg,
            .card = .hex(0x272727),
            .border = bg.mix(white, 0.08),
            .well = .hex(0x2f2f2f),
            .empty = .hex(0x3a3a3a),
            .separator = bg.mix(white, 0.09),
            .text = .hex(0xf2f2f2),
            .secondary = .hex(0xa6a6a6),
            .tertiary = .hex(0x6e6e6e),
            .accent = blue,
            .stripe = .hex(0x222222),
            .selection = bg.mix(blue, 0.30),
            .on_selection = white,
            .marked = bg.mix(blue, 0.14),
            .control = .hex(0x2d2d2d),
            .control_on = .hex(0x3d3d3d),
            .hover = white.alpha(0.06),
            .user = .hex(0x3b8eea),
            .system = .hex(0xf25c54),
            .fast = .hex(0x3b8eea),
            .frugal = .hex(0x7fb4f0),
            .gray = .hex(0x9a9a9a),
            .blue = .hex(0x3b8eea),
            .green = .hex(0x3ec46d),
            .red = .hex(0xf5546f),
            .orange = .hex(0xf5a03a),
            .teal = .hex(0x2bbfbf),
            .purple = .hex(0xb58cf2),
            .yellow = .hex(0xf5c02a),
            .sky = .hex(0x4cc2f0),
            .warm = .hex(0xf5a03a),
            .hot = .hex(0xf5546f),
        };
    }
    const bg = Color.hex(0xffffff);
    const blue = Color.hex(0x0f6cd6);
    return .{
        .sidebar = .hex(0xf3f3f3),
        .picked = blue,
        .on_picked = white,
        .page = bg,
        .card = .hex(0xf3f3f5),
        .border = bg.mix(black, 0.08),
        .well = .hex(0xe9e9ec),
        .empty = .hex(0xd9d9de),
        .separator = bg.mix(black, 0.09),
        .text = .hex(0x1b1b1b),
        .secondary = .hex(0x5f5f5f),
        .tertiary = .hex(0x9a9a9a),
        .accent = blue,
        .stripe = .hex(0xf7f7f8),
        .selection = bg.mix(blue, 0.16),
        .on_selection = .hex(0x1b1b1b),
        .marked = bg.mix(blue, 0.07),
        .control = .hex(0xebebee),
        .control_on = white,
        .hover = black.alpha(0.045),
        .user = .hex(0x1f7ae0),
        .system = .hex(0xee4040),
        .fast = .hex(0x1f7ae0),
        .frugal = .hex(0x7fb0ec),
        .gray = .hex(0x6e6e73),
        .blue = .hex(0x1f7ae0),
        .green = .hex(0x22a447),
        .red = .hex(0xee3a5c),
        .orange = .hex(0xef8b16),
        .teal = .hex(0x10a2a2),
        .purple = .hex(0x8a5cd6),
        .yellow = .hex(0xe8a500),
        .sky = .hex(0x2ea8e6),
        .warm = .hex(0xef7a16),
        .hot = .hex(0xe8323c),
    };
}

pub fn ui(dark: bool) myzig.ui.Theme {
    const k = colors(dark);
    var t = if (dark) myzig.ui.Theme.dark_theme else myzig.ui.Theme.light;
    t.background = k.page;
    t.surface = k.control_on;
    t.surface_hover = k.control;
    t.text = k.text;
    t.muted = k.secondary;
    t.border = k.border;
    t.accent = k.accent;
    t.accent_hover = k.accent.mix(if (dark) white else black, 0.12);
    t.accent_text = k.on_picked;
    t.track = k.control;
    t.danger = k.red;
    t.success = k.green;
    if (builtin.os.tag == .windows) {
        t.font = "Segoe UI";
        t.mono_font = "Cascadia Mono";
    } else {
        t.font = "Geist";
        t.mono_font = "JetBrains Mono";
    }
    return t;
}
