const std = @import("std");
const stdx = @import("stdx");
const ft = @import("freetype");
const stbtt = @import("stbtt");

const graphics = @import("graphics.zig");
const FontId = graphics.FontId;
const OpenTypeFont = graphics.OpenTypeFont;
const log = std.log.scoped(.font);

pub const FontType = enum(u1) {
    /// Scalable font.
    Outline = 0,
    /// Scalable at fixed steps.
    Bitmap = 1,
};

/// Duped info about a font without doing a lookup.
pub const FontDesc = struct {
    font_type: FontType,

    /// Only defined for Bitmap font.
    bmfont_scaler: BitmapFontScaler,
};

pub const BitmapFontScaler = struct {
    /// Direct mapping from requested font size to the final font size and the render font size.
    mapping: [64]struct {
        bmfont_idx: u8,
        final_font_size: u16,
        render_font_size: u16,
    },
};

// Contains rendering metadata about one font face. 
// Contains the backing bitmap font size to scale to user requested font size.
pub const Font = struct {
    const Self = @This();

    id: FontId,
    font_type: FontType,
    name: []const u8,

    impl: switch (graphics.FontRendererBackend) {
        .Freetype => *ft.Face,
        // Only define for Outline font.
        .Stbtt => stbtt.fontinfo,
    },

    ot_font: OpenTypeFont,
    data: []const u8,

    /// Only defined for Bitmap font.
    bmfont_scaler: BitmapFontScaler,
    bmfont_strikes: []const BitmapFontStrike,

    pub fn initTTF(self: *Self, alloc: std.mem.Allocator, id: FontId, data: []const u8) void {
        switch (graphics.FontRendererBackend) {
            .Freetype => {
                // Dupe font data since we will be continually querying data from it.
                const own_data = alloc.dupe(u8, data) catch @panic("error");
                const ot_font = OpenTypeFont.init(alloc, own_data, 0) catch @panic("error");
                const family_name = ot_font.allocFontFamilyName(alloc) orelse @panic("error");
                self.* = .{
                    .id = id,
                    .font_type = .Outline,
                    .ot_font = ot_font,
                    .impl = undefined,
                    .name = family_name,
                    .data = own_data,
                    .bmfont_scaler = undefined,
                    .bmfont_strikes = undefined,
                };
                FreetypeBackend.initFont(graphics.ft_library, &self.impl, own_data, 0);
            },
            .Stbtt => {
                // Dupe font data since we will be continually querying data from it.
                const own_data = alloc.dupe(u8, data) catch @panic("error");

                const ot_font = OpenTypeFont.init(alloc, own_data, 0) catch @panic("error");

                var stbtt_font: stbtt.fontinfo = undefined;
                if (ot_font.hasGlyphOutlines()) {
                    stbtt.InitFont(&stbtt_font, own_data, 0) catch @panic("failed to load font");
                }

                const family_name = ot_font.allocFontFamilyName(alloc) orelse @panic("error");

                self.* = .{
                    .id = id,
                    .font_type = .Outline,
                    .ot_font = ot_font,
                    .impl = stbtt_font,
                    .name = family_name,
                    .data = own_data,
                    .bmfont_scaler = undefined,
                    .bmfont_strikes = undefined,
                };
            },
        }
    }

    pub fn initOTB(self: *Self, alloc: std.mem.Allocator, id: FontId, data: []const graphics.BitmapFontData) void {
        const strikes = alloc.alloc(BitmapFontStrike, data.len) catch @panic("error");
        var last_size: u8 = 0;
        for (data) |it, i| {
            if (it.size <= last_size) {
                @panic("Expected ascending font size.");
            }
            const own_data = alloc.dupe(u8, it.data) catch @panic("error");
            strikes[i] = .{
                .impl = undefined,
                .ot_font = OpenTypeFont.init(alloc, own_data, 0) catch @panic("failed to load font"),
                .data = own_data,
            };

            switch (graphics.FontRendererBackend) {
                .Freetype => {
                    FreetypeBackend.initFont(graphics.ft_library, &strikes[i].impl, own_data, 0);
                },
                .Stbtt => {
                    stbtt.InitFont(&strikes[i].impl, own_data, 0) catch @panic("failed to load font");
                },
            }
        }
        const family_name = strikes[0].ot_font.allocFontFamilyName(alloc) orelse unreachable;

        self.* = .{
            .id = id,
            .font_type = .Bitmap,
            .ot_font = undefined,
            .impl = undefined,
            .name = family_name,
            .data = undefined,
            .bmfont_scaler = undefined,
            .bmfont_strikes = strikes,
        };

        // Build BitmapFontScaler.
        self.bmfont_scaler.mapping = undefined;
        var cur_bm_idx: u8 = 0;
        var scale: u16 = 1;
        for (self.bmfont_scaler.mapping) |_, i| {
            var bmdata = data[cur_bm_idx];
            if (i > bmdata.size) {
                if (cur_bm_idx < data.len-1) {
                    cur_bm_idx += 1;
                    bmdata = data[cur_bm_idx];
                    scale = 1;
                } else if (i % bmdata.size == 0) {
                    // Increment the scaling factor of the current bitmap font.
                    scale = @intCast(u16, i) / bmdata.size;
                }
            }
            self.bmfont_scaler.mapping[i] = .{
                .bmfont_idx = cur_bm_idx,
                .final_font_size = bmdata.size * scale,
                .render_font_size = bmdata.size,
            };
        }
    }

    pub fn deinit(self: Self, alloc: std.mem.Allocator) void {
        switch (self.font_type) {
            .Outline => {
                self.ot_font.deinit();
                alloc.free(self.data);
            },
            .Bitmap => {
                for (self.bmfont_strikes) |font| {
                    font.deinit(alloc);
                }
                alloc.free(self.bmfont_strikes);
            },
        }
        alloc.free(self.name);
    }

    pub fn getOtFontBySize(self: Self, font_size: u16) OpenTypeFont {
        switch (self.font_type) {
            .Outline => {
                return self.ot_font;
            },
            .Bitmap => {
                if (font_size > self.bmfont_scaler.mapping.len) {
                    const mapping = self.bmfont_scaler.mapping[self.bmfont_scaler.mapping.len-1];
                    return self.bmfont_strikes[mapping.bmfont_idx].ot_font;
                } else {
                    const mapping = self.bmfont_scaler.mapping[font_size];
                    return self.bmfont_strikes[mapping.bmfont_idx].ot_font;
                }
            },
        }
    }

    pub fn getBitmapFontBySize(self: Self, font_size: u16) BitmapFontStrike {
        if (font_size > self.bmfont_scaler.mapping.len) {
            const mapping = self.bmfont_scaler.mapping[self.bmfont_scaler.mapping.len-1];
            return self.bmfont_strikes[mapping.bmfont_idx];
        } else {
            const mapping = self.bmfont_scaler.mapping[font_size];
            return self.bmfont_strikes[mapping.bmfont_idx];
        }
    }

    pub fn getKernAdvance(self: Self, prev_glyph_id: u16, glyph_id: u16) i32 {
        switch (graphics.FontRendererBackend) {
            .Stbtt => {
                const res = stbtt.stbtt_GetGlyphKernAdvance(&self.impl, prev_glyph_id, glyph_id);
                if (res != 0) {
                    log.debug("kerning: {}", .{res});
                }
                return res;
            },
            .Freetype => {
                var res: ft.FT_Vector = undefined;
                // Return unscaled so it's not dependent on the current font size setting.
                const err = ft.FT_Get_Kerning(self.impl, prev_glyph_id, glyph_id, ft.FT_KERNING_UNSCALED, &res);
                if (err != 0) {
                    log.debug("freetype error {}: {s}", .{err, ft.FT_Error_String(err)});
                    return 0;
                }
                return @intCast(i32, res.x);
            }
        }
    }
};

pub const BitmapFontStrike = struct {
    /// This is only used to get kern values. Once that is implemented in ttf.zig, this won't be needed anymore.
    impl: switch (graphics.FontRendererBackend) {
        .Stbtt => stbtt.fontinfo,
        .Freetype => *ft.Face,
    },
    ot_font: OpenTypeFont,
    data: []const u8,

    const Self = @This();

    fn deinit(self: Self, alloc: std.mem.Allocator) void {
        self.ot_font.deinit();
        alloc.free(self.data);
    }

    pub fn getKernAdvance(self: Self, prev_glyph_id: u16, glyph_id: u16) i32 {
        switch (graphics.FontRendererBackend) {
            .Stbtt => return stbtt.stbtt_GetGlyphKernAdvance(&self.impl, prev_glyph_id, glyph_id),
            .Freetype => {
                var res: ft.FT_Vector = undefined;
                // Return unscaled so it's not dependent on the current font size setting.
                const err = ft.FT_Get_Kerning(self.impl, prev_glyph_id, glyph_id, ft.FT_KERNING_UNSCALED, &res);
                if (err != 0) {
                    log.debug("freetype error {}: {s}", .{err, ft.FT_Error_String(err)});
                    return 0;
                }
                return @intCast(i32, res.x);
            },
        }
    }
};

const FreetypeBackend = struct {

    pub fn initFont(lib: ft.FT_Library, face: **ft.Face, data: []const u8, face_idx: u32) void {
        const err = ft.FT_New_Memory_Face(lib, data.ptr, @intCast(c_long, data.len), @intCast(c_long, face_idx), @ptrCast([*c][*c]ft.Face, face));
        if (err != 0) {
            stdx.panicFmt("freetype error {}: {s}", .{err, ft.FT_Error_String(err)});
        }
        face.*.glyph[0].format = ft.FT_GLYPH_FORMAT_BITMAP;
    }
};