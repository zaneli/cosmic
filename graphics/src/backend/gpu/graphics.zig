const std = @import("std");
const stdx = @import("stdx");
const ds = stdx.ds;
const platform = @import("platform");
const stbi = @import("stbi");
const math = stdx.math;
const Vec2 = math.Vec2;
const vec2 = math.Vec2.init;
const Mat4 = math.Mat4;
const geom = math.geom;
const gl = @import("gl");
const vk = @import("vk");
const builtin = @import("builtin");
const lyon = @import("lyon");
const tess2 = @import("tess2");
const pt = lyon.initPt;
const t = stdx.testing;
const trace = stdx.debug.tracy.trace;
const build_options = @import("build_options");
const Backend = build_options.GraphicsBackend;

const graphics = @import("../../graphics.zig");
const QuadBez = graphics.curve.QuadBez;
const SubQuadBez = graphics.curve.SubQuadBez;
const CubicBez = graphics.curve.CubicBez;
const Color = graphics.Color;
const BlendMode = graphics.BlendMode;
const Transform = graphics.transform.Transform;
const VMetrics = graphics.font.VMetrics;
const TextMetrics = graphics.TextMetrics;
const Font = graphics.font.Font;
pub const font_cache = @import("font_cache.zig");
pub const FontCache = font_cache.FontCache;
const ImageId = graphics.ImageId;
const TextAlign = graphics.TextAlign;
const TextBaseline = graphics.TextBaseline;
const FontId = graphics.FontId;
const FontGroupId = graphics.FontGroupId;
const log = stdx.log.scoped(.graphics_gl);
const mesh = @import("mesh.zig");
const VertexData = mesh.VertexData;
const TexShaderVertex = mesh.TexShaderVertex;
const Batcher = @import("batcher.zig").Batcher;
const text_renderer = @import("text_renderer.zig");
pub const TextGlyphIterator = text_renderer.TextGlyphIterator;
const RenderTextIterator = text_renderer.RenderTextIterator;
const svg = graphics.svg;
const stroke = @import("stroke.zig");
const tessellator = @import("../../tessellator.zig");
const Tessellator = tessellator.Tessellator;
pub const RenderFont = @import("render_font.zig").RenderFont;
pub const Glyph = @import("glyph.zig").Glyph;
const gvk = graphics.vk;
const VkContext = gvk.VkContext;
const image = @import("image.zig");
pub const ImageStore = image.ImageStore;
pub const Image = image.Image;
pub const ImageTex = image.ImageTex;

const vera_ttf = @embedFile("../../../../assets/vera.ttf");

const IsWasm = builtin.target.isWasm();

/// Having 2 frames "in flight" to draw on allows the cpu and gpu to work in parallel. More than 2 is not recommended right now.
/// This doesn't have to match the number of swap chain images/framebuffers. This indicates the max number of frames that can be active at any moment.
/// Once this limit is reached, the cpu will block until the gpu is done with the oldest frame.
/// Currently used explicitly by the Vulkan implementation.
pub const MaxActiveFrames = 2;

/// Should be agnostic to viewport dimensions so it can be reused to draw on different viewports.
pub const Graphics = struct {
    alloc: std.mem.Allocator,

    white_tex: image.ImageTex,
    inner: switch (Backend) {
        .OpenGL => struct {
            pipelines: graphics.gl.Pipelines,
        },
        .Vulkan => struct {
            ctx: VkContext,
            pipelines: gvk.Pipelines,
            tex_desc_pool: vk.VkDescriptorPool,
            tex_desc_set_layout: vk.VkDescriptorSetLayout,
            cur_cmd_buf: vk.VkCommandBuffer,
        },
        else => @compileError("unsupported"),
    },
    batcher: Batcher,
    font_cache: FontCache,

    cur_proj_transform: Transform,
    view_transform: Transform,
    cur_buf_width: u32,
    cur_buf_height: u32,

    default_font_id: FontId,
    default_font_gid: FontGroupId,
    cur_font_gid: FontGroupId,
    cur_font_size: f32,
    cur_text_align: TextAlign,
    cur_text_baseline: TextBaseline,

    cur_fill_color: Color,
    cur_stroke_color: Color,
    cur_line_width: f32,
    cur_line_width_half: f32,

    clear_color: Color,

    // Depth pixel ratio:
    // This is used to fetch a higher res font bitmap for high dpi displays.
    // eg. 18px user font size would normally use a 32px backed font bitmap but with dpr=2,
    // it would use a 64px bitmap font instead.
    cur_dpr: u8,

    image_store: image.ImageStore,

    // Draw state stack.
    state_stack: std.ArrayList(DrawState),

    cur_clip_rect: geom.Rect,
    cur_scissors: bool,
    cur_blend_mode: BlendMode,

    vec2_helper_buf: std.ArrayList(Vec2),
    vec2_slice_helper_buf: std.ArrayList([]const Vec2),
    qbez_helper_buf: std.ArrayList(SubQuadBez),
    tessellator: Tessellator,

    /// Temporary buffer used to rasterize a glyph by a backend (eg. stbtt).
    raster_glyph_buffer: std.ArrayList(u8),

    const Self = @This();

    pub fn initGL(self: *Self, alloc: std.mem.Allocator, dpr: u8) void {
        self.initDefault(alloc, dpr);
        self.initCommon(alloc);

        const max_total_textures = gl.getMaxTotalTextures();
        const max_fragment_textures = gl.getMaxFragmentTextures();
        log.debug("max frag textures: {}, max total textures: {}", .{ max_fragment_textures, max_total_textures });

        // Builtin shaders use the same vert buffer.
        var vert_buf_id: gl.GLuint = undefined;
        gl.genBuffers(1, &vert_buf_id);

        // Initialize pipelines.
        self.inner.pipelines.tex = graphics.gl.TexShader.init(vert_buf_id);
        self.inner.pipelines.gradient = graphics.gl.GradientShader.init(vert_buf_id);

        self.batcher = Batcher.initGL(alloc, vert_buf_id, self.inner.pipelines, &self.image_store);

        // 2D graphics for now. Turn off 3d options.
        gl.disable(gl.GL_DEPTH_TEST);
        gl.disable(gl.GL_CULL_FACE);

        // Enable blending by default.
        gl.enable(gl.GL_BLEND);
    }

    pub fn initVK(self: *Self, alloc: std.mem.Allocator, dpr: u8, vk_ctx: VkContext) void {
        self.initDefault(alloc, dpr);
        self.inner.ctx = vk_ctx;
        self.inner.tex_desc_set_layout = gvk.createTexDescriptorSetLayout(vk_ctx.device);
        self.inner.tex_desc_pool = gvk.createTexDescriptorPool(vk_ctx.device);
        self.initCommon(alloc);

        var vert_buf: vk.VkBuffer = undefined;
        var vert_buf_mem: vk.VkDeviceMemory = undefined;
        gvk.buffer.createVertexBuffer(vk_ctx.physical, vk_ctx.device, 40 * 10000, &vert_buf, &vert_buf_mem);

        var index_buf: vk.VkBuffer = undefined;
        var index_buf_mem: vk.VkDeviceMemory = undefined;
        gvk.buffer.createIndexBuffer(vk_ctx.physical, vk_ctx.device, 2 * 10000 * 3, &index_buf, &index_buf_mem);

        self.inner.pipelines.tex_pipeline = gvk.createTexPipeline(vk_ctx.device, vk_ctx.pass, vk_ctx.framebuffer_size, self.inner.tex_desc_set_layout, true);
        self.inner.pipelines.tex_pipeline_2d = gvk.createTexPipeline(vk_ctx.device, vk_ctx.pass, vk_ctx.framebuffer_size, self.inner.tex_desc_set_layout, false);
        self.inner.pipelines.gradient_pipeline_2d = gvk.createGradientPipeline(vk_ctx.device, vk_ctx.pass, vk_ctx.framebuffer_size);

        self.batcher = Batcher.initVK(alloc, vert_buf, vert_buf_mem, index_buf, index_buf_mem, vk_ctx, self.inner.pipelines, &self.image_store);
    }
    
    fn initDefault(self: *Self, alloc: std.mem.Allocator, dpr: u8) void {
        self.* = .{
            .alloc = alloc,
            .white_tex = undefined,
            .inner = undefined,
            .batcher = undefined,
            .font_cache = undefined,
            .default_font_id = undefined,
            .default_font_gid = undefined,
            .cur_buf_width = 0,
            .cur_buf_height = 0,
            .cur_font_gid = undefined,
            .cur_font_size = undefined,
            .cur_fill_color = Color.Black,
            .cur_stroke_color = Color.Black,
            .cur_blend_mode = ._undefined,
            .cur_line_width = undefined,
            .cur_line_width_half = undefined,
            .cur_proj_transform = undefined,
            .view_transform = undefined,
            .image_store = image.ImageStore.init(alloc, self),
            .state_stack = std.ArrayList(DrawState).init(alloc),
            .cur_clip_rect = undefined,
            .cur_scissors = undefined,
            .cur_text_align = .Left,
            .cur_text_baseline = .Top,
            .cur_dpr = dpr,
            .vec2_helper_buf = std.ArrayList(Vec2).init(alloc),
            .vec2_slice_helper_buf = std.ArrayList([]const Vec2).init(alloc),
            .qbez_helper_buf = std.ArrayList(SubQuadBez).init(alloc),
            .tessellator = undefined,
            .raster_glyph_buffer = std.ArrayList(u8).init(alloc),
            .clear_color = undefined,
        };
    }

    fn initCommon(self: *Self, alloc: std.mem.Allocator) void {
        self.tessellator.init(alloc);

        // Generate basic solid color texture.
        var buf: [16]u32 = undefined;
        std.mem.set(u32, &buf, 0xFFFFFFFF);
        self.white_tex = self.image_store.createImageFromBitmap(4, 4, std.mem.sliceAsBytes(buf[0..]), false);

        self.font_cache.init(alloc, self);

        // TODO: Embed a default bitmap font.
        // TODO: Embed a default ttf monospace font.

        self.default_font_id = self.addFontTTF(vera_ttf);
        self.default_font_gid = self.font_cache.getOrLoadFontGroup(&.{self.default_font_id});
        self.setFont(self.default_font_id);

        // Set default font size.
        self.setFontSize(20);

        // View transform can be changed by user transforms.
        self.view_transform = Transform.initIdentity();

        self.setLineWidth(1);

        if (build_options.has_lyon) {
            lyon.init();
        }

        // Clear color. Default to white.
        self.setClearColor(Color.White);
        // gl.clearColor(0.1, 0.2, 0.3, 1.0);
        // gl.clearColor(0, 0, 0, 1.0);
    }

    pub fn deinit(self: *Self) void {
        switch (Backend) {
            .OpenGL => {
                self.inner.pipelines.deinit();
            },
            .Vulkan => {
                const device = self.inner.ctx.device;
                self.inner.pipelines.deinit(device);

                vk.destroyDescriptorSetLayout(device, self.inner.tex_desc_set_layout, null);
                vk.destroyDescriptorPool(device, self.inner.tex_desc_pool, null);
            },
            else => {},
        }
        self.batcher.deinit();
        self.font_cache.deinit();
        self.state_stack.deinit();

        if (build_options.has_lyon) {
            lyon.deinit();
        }

        self.image_store.deinit();

        self.vec2_helper_buf.deinit();
        self.vec2_slice_helper_buf.deinit();
        self.qbez_helper_buf.deinit();
        self.tessellator.deinit();
        self.raster_glyph_buffer.deinit();
    }

    pub fn addFontOTB(self: *Self, data: []const graphics.BitmapFontData) FontId {
        return self.font_cache.addFontOTB(data);
    }

    pub fn addFontTTF(self: *Self, data: []const u8) FontId {
        return self.font_cache.addFontTTF(data);
    }

    pub fn addFallbackFont(self: *Self, font_id: FontId) void {
        self.font_cache.addSystemFont(font_id) catch unreachable;
    }

    pub fn clipRect(self: *Self, x: f32, y: f32, width: f32, height: f32) void {
        // log.debug("clipRect {} {} {} {}", .{x, y, width, height});

        switch (Backend) {
            .OpenGL => {
                self.cur_clip_rect = .{
                    .x = x,
                    // clip-y starts at bottom.
                    .y = @intToFloat(f32, self.cur_buf_height) - (y + height),
                    .width = width,
                    .height = height,
                };
            },
            .Vulkan => {
                self.cur_clip_rect = .{
                    .x = x,
                    .y = y,
                    .width = width,
                    .height = height,
                };
            },
            else => {},
        }
        self.cur_scissors = true;

        // Execute current draw calls before we alter state.
        self.endCmd();

        self.clipRectCmd(self.cur_clip_rect);
    }

    fn clipRectCmd(self: Self, rect: geom.Rect) void {
        switch (Backend) {
            .OpenGL => {
                gl.scissor(@floatToInt(c_int, rect.x), @floatToInt(c_int, rect.y), @floatToInt(c_int, rect.width), @floatToInt(c_int, rect.height));
                gl.enable(gl.GL_SCISSOR_TEST);
            },
            .Vulkan => {
                const vk_rect = vk.VkRect2D{
                    .offset = .{
                        .x = @floatToInt(i32, rect.x),
                        .y = @floatToInt(i32, rect.y),
                    },
                    .extent = .{
                        .width = @floatToInt(u32, rect.width),
                        .height = @floatToInt(u32, rect.height),
                    },
                };
                vk.cmdSetScissor(self.inner.cur_cmd_buf, 0, 1, &vk_rect);
            },
            else => {},
        }
    }

    pub fn resetTransform(self: *Self) void {
        self.view_transform.reset();
        const mvp = self.view_transform.getAppliedTransform(self.cur_proj_transform);
        self.batcher.beginMvp(mvp);
    }

    pub fn pushState(self: *Self) void {
        self.state_stack.append(.{
            .clip_rect = self.cur_clip_rect,
            .use_scissors = self.cur_scissors,
            .blend_mode = self.cur_blend_mode,
            .view_transform = self.view_transform,
        }) catch unreachable;
    }

    pub fn popState(self: *Self) void {
        // log.debug("popState", .{});

        // Execute current draw calls before altering state.
        self.endCmd();

        const state = self.state_stack.pop();
        if (state.use_scissors) {
            const r = state.clip_rect;
            self.clipRect(r.x, r.y, r.width, r.height);
        } else {
            self.cur_scissors = false;
            switch (Backend) {
                .OpenGL => {
                    gl.disable(gl.GL_SCISSOR_TEST);
                },
                .Vulkan => {
                    const r = state.clip_rect;
                    self.clipRect(r.x, r.y, r.width, r.height);
                },
                else => {},
            }
        }
        if (state.blend_mode != self.cur_blend_mode) {
            self.setBlendMode(state.blend_mode);
        }
        if (!std.meta.eql(self.view_transform.mat, state.view_transform.mat)) {
            self.view_transform = state.view_transform;
            const mvp = self.view_transform.getAppliedTransform(self.cur_proj_transform);
            self.batcher.mvp = mvp;
        }
    }

    pub fn getViewTransform(self: Self) Transform {
        return self.view_transform;
    }

    pub fn getLineWidth(self: Self) f32 {
        return self.cur_line_width;
    }

    pub fn setLineWidth(self: *Self, width: f32) void {
        self.cur_line_width = width;
        self.cur_line_width_half = width * 0.5;
    }

    pub fn setFont(self: *Self, font_id: FontId) void {
        // Lookup font group single font.
        const font_gid = self.font_cache.getOrLoadFontGroup(&.{font_id});
        self.setFontGroup(font_gid);
    }

    pub fn setFontGroup(self: *Self, font_gid: FontGroupId) void {
        if (font_gid != self.cur_font_gid) {
            self.cur_font_gid = font_gid;
        }
    }

    pub inline fn clear(self: Self) void {
        _ = self;
        gl.clear(gl.GL_COLOR_BUFFER_BIT);
    }

    pub fn setClearColor(self: *Self, color: Color) void {
        self.clear_color = color;
        if (Backend == .OpenGL) {
            const f = color.toFloatArray();
            gl.clearColor(f[0], f[1], f[2], f[3]);
        }
    }

    pub fn getFillColor(self: Self) Color {
        return self.cur_fill_color;
    }

    pub fn setFillColor(self: *Self, color: Color) void {
        self.batcher.beginTex(self.white_tex);
        self.cur_fill_color = color;
    }

    pub fn setFillGradient(self: *Self, start_x: f32, start_y: f32, start_color: Color, end_x: f32, end_y: f32, end_color: Color) void {
        // Convert to screen coords on cpu.
        const start_screen_pos = self.view_transform.interpolatePt(vec2(start_x, start_y));
        const end_screen_pos = self.view_transform.interpolatePt(vec2(end_x, end_y));
        self.batcher.beginGradient(start_screen_pos, start_color, end_screen_pos, end_color);
    }

    pub fn getStrokeColor(self: Self) Color {
        return self.cur_stroke_color;
    }

    pub fn setStrokeColor(self: *Self, color: Color) void {
        self.cur_stroke_color = color;
    }

    pub fn getFontSize(self: Self) f32 {
        return self.cur_font_size;
    }

    pub fn getOrLoadFontGroupByFamily(self: *Self, family: graphics.FontFamily) FontGroupId {
        switch (family) {
            .Name => {
                return self.font_cache.getOrLoadFontGroupByNameSeq(&.{family.Name}).?;
            },
            .FontGroup => return family.FontGroup,
            .Font => return self.font_cache.getOrLoadFontGroup(&.{ family.Font }),
            .Default => return self.default_font_gid,
        }
    }

    pub fn setFontSize(self: *Self, size: f32) void {
        if (self.cur_font_size != size) {
            self.cur_font_size = size;
        }
    }

    pub fn setTextAlign(self: *Self, align_: TextAlign) void {
        self.cur_text_align = align_;
    }

    pub fn setTextBaseline(self: *Self, baseline: TextBaseline) void {
        self.cur_text_baseline = baseline;
    }

    pub fn measureText(self: *Self, str: []const u8, res: *TextMetrics) void {
        text_renderer.measureText(self, self.cur_font_gid, self.cur_font_size, self.cur_dpr, str, res, true);
    }

    pub fn measureFontText(self: *Self, group_id: FontGroupId, size: f32, str: []const u8, res: *TextMetrics) void {
        text_renderer.measureText(self, group_id, size, self.cur_dpr, str, res, true);
    }

    pub inline fn textGlyphIter(self: *Self, font_gid: FontGroupId, size: f32, str: []const u8) graphics.TextGlyphIterator {
        return text_renderer.textGlyphIter(self, font_gid, size, self.cur_dpr, str);
    }

    pub fn fillText(self: *Self, x: f32, y: f32, str: []const u8) void {
        // log.info("draw text '{s}'", .{str});
        var vert: TexShaderVertex = undefined;

        var vdata: VertexData(4, 6) = undefined;

        var start_x = x;
        var start_y = y;

        if (self.cur_text_align != .Left) {
            var metrics: TextMetrics = undefined;
            self.measureText(str, &metrics);
            switch (self.cur_text_align) {
                .Left => {},
                .Right => start_x = x-metrics.width,
                .Center => start_x = x-metrics.width/2,
            }
        }
        if (self.cur_text_baseline != .Top) {
            const vmetrics = self.font_cache.getPrimaryFontVMetrics(self.cur_font_gid, self.cur_font_size);
            switch (self.cur_text_baseline) {
                .Top => {},
                .Middle => start_y = y - vmetrics.height / 2,
                .Alphabetic => start_y = y - vmetrics.ascender,
                .Bottom => start_y = y - vmetrics.height,
            }
        }
        var iter = text_renderer.RenderTextIterator.init(self, self.cur_font_gid, self.cur_font_size, self.cur_dpr, start_x, start_y, str);

        while (iter.nextCodepointQuad(true)) {
            self.setCurrentTexture(iter.quad.image);

            if (iter.quad.is_color_bitmap) {
                vert.setColor(Color.White);
            } else {
                vert.setColor(self.cur_fill_color);
            }

            // top left
            vert.setXY(iter.quad.x0, iter.quad.y0);
            vert.setUV(iter.quad.u0, iter.quad.v0);
            vdata.verts[0] = vert;

            // top right
            vert.setXY(iter.quad.x1, iter.quad.y0);
            vert.setUV(iter.quad.u1, iter.quad.v0);
            vdata.verts[1] = vert;

            // bottom right
            vert.setXY(iter.quad.x1, iter.quad.y1);
            vert.setUV(iter.quad.u1, iter.quad.v1);
            vdata.verts[2] = vert;

            // bottom left
            vert.setXY(iter.quad.x0, iter.quad.y1);
            vert.setUV(iter.quad.u0, iter.quad.v1);
            vdata.verts[3] = vert;

            // indexes
            vdata.setRect(0, 0, 1, 2, 3);

            self.pushVertexData(4, 6, &vdata);
        }
    }

    pub inline fn setCurrentTexture(self: *Self, image_tex: image.ImageTex) void {
        self.batcher.beginTexture(image_tex);
    }

    fn ensureUnusedBatchCapacity(self: *Self, vert_inc: usize, index_inc: usize) void {
        if (!self.batcher.ensureUnusedBuffer(vert_inc, index_inc)) {
            self.endCmd();
        }
    }

    fn pushLyonVertexData(self: *Self, data: *lyon.VertexData, color: Color) void {
        self.ensureUnusedBatchCapacity(data.vertex_len, data.index_len);
        self.batcher.pushLyonVertexData(data, color);
    }

    fn pushVertexData(self: *Self, comptime num_verts: usize, comptime num_indices: usize, data: *VertexData(num_verts, num_indices)) void {
        self.ensureUnusedBatchCapacity(num_verts, num_indices);
        self.batcher.pushVertexData(num_verts, num_indices, data);
    }

    pub fn drawRectVec(self: *Self, pos: Vec2, width: f32, height: f32) void {
        self.drawRect(pos.x, pos.y, width, height);
    }

    pub fn drawRect(self: *Self, x: f32, y: f32, width: f32, height: f32) void {
        self.batcher.beginTex(self.white_tex);
        // Top border.
        self.fillRectColor(x - self.cur_line_width_half, y - self.cur_line_width_half, width + self.cur_line_width, self.cur_line_width, self.cur_stroke_color);
        // Right border.
        self.fillRectColor(x + width - self.cur_line_width_half, y + self.cur_line_width_half, self.cur_line_width, height - self.cur_line_width, self.cur_stroke_color);
        // Bottom border.
        self.fillRectColor(x - self.cur_line_width_half, y + height - self.cur_line_width_half, width + self.cur_line_width, self.cur_line_width, self.cur_stroke_color);
        // Left border.
        self.fillRectColor(x - self.cur_line_width_half, y + self.cur_line_width_half, self.cur_line_width, height - self.cur_line_width, self.cur_stroke_color);
    }

    // Uses path rendering.
    pub fn strokeRectLyon(self: *Self, x: f32, y: f32, width: f32, height: f32) void {
        self.batcher.beginTex(self.white_tex);
        // log.debug("strokeRect {d:.2} {d:.2} {d:.2} {d:.2}", .{pos.x, pos.y, width, height});
        const b = lyon.initBuilder();
        lyon.addRectangle(b, &.{ .x = x, .y = y, .width = width, .height = height });
        var data = lyon.buildStroke(b, self.cur_line_width);

        self.setCurrentTexture(self.white_tex);
        self.pushLyonVertexData(&data, self.cur_stroke_color);
    }

    pub fn fillRoundRect(self: *Self, x: f32, y: f32, width: f32, height: f32, radius: f32) void {
        // Top left corner.
        self.fillCircleSectorN(x + radius, y + radius, radius, math.pi, math.pi_half, 90);
        // Left side.
        self.fillRect(x, y + radius, radius, height - radius * 2);
        // Bottom left corner.
        self.fillCircleSectorN(x + radius, y + height - radius, radius, math.pi_half, math.pi_half, 90);
        // Middle.
        self.fillRect(x + radius, y, width - radius * 2, height);
        // Top right corner.
        self.fillCircleSectorN(x + width - radius, y + radius, radius, -math.pi_half, math.pi_half, 90);
        // Right side.
        self.fillRect(x + width - radius, y + radius, radius, height - radius * 2);
        // Bottom right corner.
        self.fillCircleSectorN(x + width - radius, y + height - radius, radius, 0, math.pi_half, 90);
    }

    pub fn drawRoundRect(self: *Self, x: f32, y: f32, width: f32, height: f32, radius: f32) void {
        self.batcher.beginTex(self.white_tex);
        // Top left corner.
        self.drawCircleArcN(x + radius, y + radius, radius, math.pi, math.pi_half, 90);
        // Left side.
        self.fillRectColor(x - self.cur_line_width_half, y + radius, self.cur_line_width, height - radius * 2, self.cur_stroke_color);
        // Bottom left corner.
        self.drawCircleArcN(x + radius, y + height - radius, radius, math.pi_half, math.pi_half, 90);
        // Top.
        self.fillRectColor(x + radius, y - self.cur_line_width_half, width - radius * 2, self.cur_line_width, self.cur_stroke_color);
        // Bottom.
        self.fillRectColor(x + radius, y + height - self.cur_line_width_half, width - radius * 2, self.cur_line_width, self.cur_stroke_color);
        // Top right corner.
        self.drawCircleArcN(x + width - radius, y + radius, radius, -math.pi_half, math.pi_half, 90);
        // Right side.
        self.fillRectColor(x + width - self.cur_line_width_half, y + radius, self.cur_line_width, height - radius * 2, self.cur_stroke_color);
        // Bottom right corner.
        self.drawCircleArcN(x + width - radius, y + height - radius, radius, 0, math.pi_half, 90);
    }

    pub fn fillRect(self: *Self, x: f32, y: f32, width: f32, height: f32) void {
        self.fillRectColor(x, y, width, height, self.cur_fill_color);
    }

    // Sometimes we want to override the color (eg. rendering part of a stroke.)
    fn fillRectColor(self: *Self, x: f32, y: f32, width: f32, height: f32, color: Color) void {
        self.setCurrentTexture(self.white_tex);
        self.ensureUnusedBatchCapacity(4, 6);

        var vert: TexShaderVertex = undefined;
        vert.setColor(color);

        const start_idx = self.batcher.mesh.getNextIndexId();

        // top left
        vert.setXY(x, y);
        vert.setUV(0, 0);
        self.batcher.mesh.addVertex(&vert);

        // top right
        vert.setXY(x + width, y);
        vert.setUV(1, 0);
        self.batcher.mesh.addVertex(&vert);

        // bottom right
        vert.setXY(x + width, y + height);
        vert.setUV(1, 1);
        self.batcher.mesh.addVertex(&vert);

        // bottom left
        vert.setXY(x, y + height);
        vert.setUV(0, 1);
        self.batcher.mesh.addVertex(&vert);

        // add rect
        self.batcher.mesh.addQuad(start_idx, start_idx + 1, start_idx + 2, start_idx + 3);
    }

    pub fn drawCircleArc(self: *Self, x: f32, y: f32, radius: f32, start_rad: f32, sweep_rad: f32) void {
        self.batcher.beginTex(self.white_tex);
        if (builtin.mode == .Debug) {
            stdx.debug.assertInRange(start_rad, -math.pi_2, math.pi_2);
            stdx.debug.assertInRange(sweep_rad, -math.pi_2, math.pi_2);
        }
        // Approx 1 arc sector per degree.
        var n = @floatToInt(u32, @ceil(@fabs(sweep_rad) / math.pi_2 * 360));
        self.drawCircleArcN(x, y, radius, start_rad, sweep_rad, n);
    }

    // n is the number of sections in the arc we will draw.
    pub fn drawCircleArcN(self: *Self, x: f32, y: f32, radius: f32, start_rad: f32, sweep_rad: f32, n: u32) void {
        self.batcher.beginTex(self.white_tex);
        self.ensureUnusedBatchCapacity(2 + n * 2, n * 3 * 2);

        const inner_rad = radius - self.cur_line_width_half;
        const outer_rad = radius + self.cur_line_width_half;

        var vert: TexShaderVertex = undefined;
        vert.setColor(self.cur_stroke_color);
        vert.setUV(0, 0); // Currently we don't do uv mapping for strokes.

        // Add first two vertices.
        var cos = @cos(start_rad);
        var sin = @sin(start_rad);
        vert.setXY(x + cos * inner_rad, y + sin * inner_rad);
        self.batcher.mesh.addVertex(&vert);
        vert.setXY(x + cos * outer_rad, y + sin * outer_rad);
        self.batcher.mesh.addVertex(&vert);

        const rad_per_n = sweep_rad / @intToFloat(f32, n);
        var cur_vert_idx = self.batcher.mesh.getNextIndexId();
        var i: u32 = 1;
        while (i <= n) : (i += 1) {
            const rad = start_rad + rad_per_n * @intToFloat(f32, i);

            // Add inner/outer vertex.
            cos = @cos(rad);
            sin = @sin(rad);
            vert.setXY(x + cos * inner_rad, y + sin * inner_rad);
            self.batcher.mesh.addVertex(&vert);
            vert.setXY(x + cos * outer_rad, y + sin * outer_rad);
            self.batcher.mesh.addVertex(&vert);

            // Add arc sector.
            self.batcher.mesh.addQuad(cur_vert_idx - 1, cur_vert_idx + 1, cur_vert_idx, cur_vert_idx - 2);
            cur_vert_idx += 2;
        }
    }

    pub fn fillCircleSectorN(self: *Self, x: f32, y: f32, radius: f32, start_rad: f32, sweep_rad: f32, num_tri: u32) void {
        self.setCurrentTexture(self.white_tex);
        self.ensureUnusedBatchCapacity(num_tri + 2, num_tri * 3);

        var vert: TexShaderVertex = undefined;
        vert.setColor(self.cur_fill_color);

        // Add center.
        const center = self.batcher.mesh.getNextIndexId();
        vert.setUV(0.5, 0.5);
        vert.setXY(x, y);
        self.batcher.mesh.addVertex(&vert);

        // Add first circle vertex.
        var cos = @cos(start_rad);
        var sin = @sin(start_rad);
        vert.setUV(0.5 + cos, 0.5 + sin);
        vert.setXY(x + cos * radius, y + sin * radius);
        self.batcher.mesh.addVertex(&vert);

        const rad_per_tri = sweep_rad / @intToFloat(f32, num_tri);
        var last_vert_idx = center + 1;
        var i: u32 = 1;
        while (i <= num_tri) : (i += 1) {
            const rad = start_rad + rad_per_tri * @intToFloat(f32, i);

            // Add next circle vertex.
            cos = @cos(rad);
            sin = @sin(rad);
            vert.setUV(0.5 + cos, 0.5 + sin);
            vert.setXY(x + cos * radius, y + sin * radius);
            self.batcher.mesh.addVertex(&vert);

            // Add triangle.
            const next_idx = last_vert_idx + 1;
            self.batcher.mesh.addTriangle(center, last_vert_idx, next_idx);
            last_vert_idx = next_idx;
        }
    }

    pub fn fillCircleSector(self: *Self, x: f32, y: f32, radius: f32, start_rad: f32, sweep_rad: f32) void {
        if (builtin.mode == .Debug) {
            stdx.debug.assertInRange(start_rad, -math.pi_2, math.pi_2);
            stdx.debug.assertInRange(sweep_rad, -math.pi_2, math.pi_2);
        }
        // Approx 1 triangle per degree.
        var num_tri = @floatToInt(u32, @ceil(@fabs(sweep_rad) / math.pi_2 * 360));
        self.fillCircleSectorN(x, y, radius, start_rad, sweep_rad, num_tri);
    }

    // Same implementation as fillEllipse when h_radius = v_radius.
    pub fn fillCircle(self: *Self, x: f32, y: f32, radius: f32) void {
        self.fillCircleSectorN(x, y, radius, 0, math.pi_2, 360);
    }

    // Same implementation as drawEllipse when h_radius = v_radius. Might be slightly faster since we use fewer vars.
    pub fn drawCircle(self: *Self, x: f32, y: f32, radius: f32) void {
        self.drawCircleArcN(x, y, radius, 0, math.pi_2, 360);
    }

    pub fn fillEllipseSectorN(self: *Self, x: f32, y: f32, h_radius: f32, v_radius: f32, start_rad: f32, sweep_rad: f32, n: u32) void {
        self.setCurrentTexture(self.white_tex);
        self.ensureUnusedBatchCapacity(n + 2, n * 3);

        var vert: TexShaderVertex = undefined;
        vert.setColor(self.cur_fill_color);

        // Add center.
        const center = self.batcher.mesh.getNextIndexId();
        vert.setUV(0.5, 0.5);
        vert.setXY(x, y);
        self.batcher.mesh.addVertex(&vert);

        // Add first circle vertex.
        var cos = @cos(start_rad);
        var sin = @sin(start_rad);
        vert.setUV(0.5 + cos, 0.5 + sin);
        vert.setXY(x + cos * h_radius, y + sin * v_radius);
        self.batcher.mesh.addVertex(&vert);

        const rad_per_tri = sweep_rad / @intToFloat(f32, n);
        var last_vert_idx = center + 1;
        var i: u32 = 1;
        while (i <= n) : (i += 1) {
            const rad = start_rad + rad_per_tri * @intToFloat(f32, i);

            // Add next circle vertex.
            cos = @cos(rad);
            sin = @sin(rad);
            vert.setUV(0.5 + cos, 0.5 + sin);
            vert.setXY(x + cos * h_radius, y + sin * v_radius);
            self.batcher.mesh.addVertex(&vert);

            // Add triangle.
            const next_idx = last_vert_idx + 1;
            self.batcher.mesh.addTriangle(center, last_vert_idx, next_idx);
            last_vert_idx = next_idx;
        }
    }

    pub fn fillEllipseSector(self: *Self, x: f32, y: f32, h_radius: f32, v_radius: f32, start_rad: f32, sweep_rad: f32) void {
        if (builtin.mode == .Debug) {
            stdx.debug.assertInRange(start_rad, -math.pi_2, math.pi_2);
            stdx.debug.assertInRange(sweep_rad, -math.pi_2, math.pi_2);
        }
        // Approx 1 arc section per degree.
        var n = @floatToInt(u32, @ceil(@fabs(sweep_rad) / math.pi_2 * 360));
        self.fillEllipseSectorN(x, y, h_radius, v_radius, start_rad, sweep_rad, n);
    }

    pub fn fillEllipse(self: *Self, x: f32, y: f32, h_radius: f32, v_radius: f32) void {
        self.fillEllipseSectorN(x, y, h_radius, v_radius, 0, math.pi_2, 360);
    }

    pub fn drawEllipseArc(self: *Self, x: f32, y: f32, h_radius: f32, v_radius: f32, start_rad: f32, sweep_rad: f32) void {
        if (builtin.mode == .Debug) {
            stdx.debug.assertInRange(start_rad, -math.pi_2, math.pi_2);
            stdx.debug.assertInRange(sweep_rad, -math.pi_2, math.pi_2);
        }
        // Approx 1 arc sector per degree.
        var n = @floatToInt(u32, @ceil(@fabs(sweep_rad) / math.pi_2 * 360));
        self.drawEllipseArcN(x, y, h_radius, v_radius, start_rad, sweep_rad, n);
    }

    // n is the number of sections in the arc we will draw.
    pub fn drawEllipseArcN(self: *Self, x: f32, y: f32, h_radius: f32, v_radius: f32, start_rad: f32, sweep_rad: f32, n: u32) void {
        self.batcher.beginTex(self.white_tex);
        self.ensureUnusedBatchCapacity(2 + n * 2, n * 3 * 2);

        const inner_h_rad = h_radius - self.cur_line_width_half;
        const inner_v_rad = v_radius - self.cur_line_width_half;
        const outer_h_rad = h_radius + self.cur_line_width_half;
        const outer_v_rad = v_radius + self.cur_line_width_half;

        var vert: TexShaderVertex = undefined;
        vert.setColor(self.cur_stroke_color);
        vert.setUV(0, 0); // Currently we don't do uv mapping for strokes.

        // Add first two vertices.
        var cos = @cos(start_rad);
        var sin = @sin(start_rad);
        vert.setXY(x + cos * inner_h_rad, y + sin * inner_v_rad);
        self.batcher.mesh.addVertex(&vert);
        vert.setXY(x + cos * outer_h_rad, y + sin * outer_v_rad);
        self.batcher.mesh.addVertex(&vert);

        const rad_per_n = sweep_rad / @intToFloat(f32, n);
        var cur_vert_idx = self.batcher.mesh.getNextIndexId();
        var i: u32 = 1;
        while (i <= n) : (i += 1) {
            const rad = start_rad + rad_per_n * @intToFloat(f32, i);

            // Add inner/outer vertex.
            cos = @cos(rad);
            sin = @sin(rad);
            vert.setXY(x + cos * inner_h_rad, y + sin * inner_v_rad);
            self.batcher.mesh.addVertex(&vert);
            vert.setXY(x + cos * outer_h_rad, y + sin * outer_v_rad);
            self.batcher.mesh.addVertex(&vert);

            // Add arc sector.
            self.batcher.mesh.addQuad(cur_vert_idx + 1, cur_vert_idx - 1, cur_vert_idx - 2, cur_vert_idx);
            cur_vert_idx += 2;
        }
    }

    pub fn drawEllipse(self: *Self, x: f32, y: f32, h_radius: f32, v_radius: f32) void {
        self.drawEllipseArcN(x, y, h_radius, v_radius, 0, math.pi_2, 360);
    }

    pub fn drawPoint(self: *Self, x: f32, y: f32) void {
        self.batcher.beginTex(self.white_tex);
        self.fillRectColor(x - self.cur_line_width_half, y - self.cur_line_width_half, self.cur_line_width, self.cur_line_width, self.cur_stroke_color);
    }

    pub fn drawLine(self: *Self, x1: f32, y1: f32, x2: f32, y2: f32) void {
        self.batcher.beginTex(self.white_tex);
        if (x1 == x2) {
            self.fillRectColor(x1 - self.cur_line_width_half, y1, self.cur_line_width, y2 - y1, self.cur_stroke_color);
        } else {
            const normal = vec2(y2 - y1, x2 - x1).toLength(self.cur_line_width_half);
            self.fillQuad(
                x1 - normal.x, y1 + normal.y,
                x1 + normal.x, y1 - normal.y,
                x2 + normal.x, y2 - normal.y,
                x2 - normal.x, y2 + normal.y,
                self.cur_stroke_color,
            );
        }
    }

    pub fn drawQuadraticBezierCurve(self: *Self, x0: f32, y0: f32, cx: f32, cy: f32, x1: f32, y1: f32) void {
        self.batcher.beginTex(self.white_tex);
        const q_bez = QuadBez{
            .x0 = x0,
            .y0 = y0,
            .cx = cx,
            .cy = cy,
            .x1 = x1,
            .y1 = y1,
        };
        self.vec2_helper_buf.clearRetainingCapacity();
        stroke.strokeQuadBez(&self.batcher.mesh, &self.vec2_helper_buf, q_bez, self.cur_line_width_half, self.cur_stroke_color);
    }

    pub fn drawQuadraticBezierCurveLyon(self: *Self, x0: f32, y0: f32, cx: f32, cy: f32, x1: f32, y1: f32) void {
        self.batcher.beginTex(self.white_tex);
        const b = lyon.initBuilder();
        lyon.begin(b, &pt(x0, y0));
        lyon.quadraticBezierTo(b, &pt(cx, cy), &pt(x1, y1));
        lyon.end(b, false);
        var data = lyon.buildStroke(b, self.cur_line_width);
        self.setCurrentTexture(self.white_tex);
        self.pushLyonVertexData(&data, self.cur_stroke_color);
    }

    pub fn drawCubicBezierCurve(self: *Self, x0: f32, y0: f32, cx0: f32, cy0: f32, cx1: f32, cy1: f32, x1: f32, y1: f32) void {
        self.batcher.beginTex(self.white_tex);
        const c_bez = CubicBez{
            .x0 = x0,
            .y0 = y0,
            .cx0 = cx0,
            .cy0 = cy0,
            .cx1 = cx1,
            .cy1 = cy1,
            .x1 = x1,
            .y1 = y1,
        };
        self.qbez_helper_buf.clearRetainingCapacity();
        self.vec2_helper_buf.clearRetainingCapacity();
        stroke.strokeCubicBez(&self.batcher.mesh, &self.vec2_helper_buf, &self.qbez_helper_buf, c_bez, self.cur_line_width_half, self.cur_stroke_color);
    }

    pub fn drawCubicBezierCurveLyon(self: *Self, x0: f32, y0: f32, cx0: f32, cy0: f32, cx1: f32, cy1: f32, x1: f32, y1: f32) void {
        self.batcher.beginTex(self.white_tex);
        const b = lyon.initBuilder();
        lyon.begin(b, &pt(x0, y0));
        lyon.cubicBezierTo(b, &pt(cx0, cy0), &pt(cx1, cy1), &pt(x1, y1));
        lyon.end(b, false);
        var data = lyon.buildStroke(b, self.cur_line_width);
        self.setCurrentTexture(self.white_tex);
        self.pushLyonVertexData(&data, self.cur_stroke_color);
    }

    // Points are given in ccw order. Currently doesn't map uvs.
    pub fn fillQuad(self: *Self, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32, x4: f32, y4: f32, color: Color) void {
        self.setCurrentTexture(self.white_tex);
        self.ensureUnusedBatchCapacity(4, 6);

        var vert: TexShaderVertex = undefined;
        vert.setColor(color);
        vert.setUV(0, 0); // Don't map uvs for now.

        const start_idx = self.batcher.mesh.getNextIndexId();
        vert.setXY(x1, y1);
        self.batcher.mesh.addVertex(&vert);
        vert.setXY(x2, y2);
        self.batcher.mesh.addVertex(&vert);
        vert.setXY(x3, y3);
        self.batcher.mesh.addVertex(&vert);
        vert.setXY(x4, y4);
        self.batcher.mesh.addVertex(&vert);
        self.batcher.mesh.addQuad(start_idx, start_idx + 1, start_idx + 2, start_idx + 3);
    }

    pub fn fillSvgPath(self: *Self, x: f32, y: f32, path: *const svg.SvgPath) void {
        const t_ = trace(@src());
        defer t_.end();
        self.drawSvgPath(x, y, path, true);
    }

    pub fn fillSvgPathLyon(self: *Self, x: f32, y: f32, path: *const svg.SvgPath) void {
        const t_ = trace(@src());
        defer t_.end();
        self.drawSvgPathLyon(x, y, path, true);
    }

    pub fn fillSvgPathTess2(self: *Self, x: f32, y: f32, path: *const svg.SvgPath) void {
        const t_ = trace(@src());
        defer t_.end();
        _ = x;
        _ = y;

        // Accumulate polygons.
        self.vec2_helper_buf.clearRetainingCapacity();
        self.vec2_slice_helper_buf.clearRetainingCapacity();
        self.qbez_helper_buf.clearRetainingCapacity();

        var last_cmd_was_curveto = false;
        var last_control_pt = vec2(0, 0);
        var cur_data_idx: u32 = 0;
        var cur_pt = vec2(0, 0);
        var cur_poly_start: u32 = 0;

        for (path.cmds) |cmd| {
            var cmd_is_curveto = false;
            switch (cmd) {
                .MoveTo => {
                    if (self.vec2_helper_buf.items.len > cur_poly_start + 1) {
                        self.vec2_slice_helper_buf.append(self.vec2_helper_buf.items[cur_poly_start..]) catch unreachable;
                    } else if (self.vec2_helper_buf.items.len == cur_poly_start + 1) {
                        // Only one unused point. Remove it.
                        _ = self.vec2_helper_buf.pop();
                    }
                    const data = path.getData(.MoveTo, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.MoveTo)) / 4;
                    cur_pt = .{
                        .x = data.x,
                        .y = data.y,
                    };
                    cur_poly_start = @intCast(u32, self.vec2_helper_buf.items.len);
                    self.vec2_helper_buf.append(cur_pt) catch unreachable;
                },
                .MoveToRel => {
                    if (self.vec2_helper_buf.items.len > cur_poly_start + 1) {
                        self.vec2_slice_helper_buf.append(self.vec2_helper_buf.items[cur_poly_start..]) catch unreachable;
                    } else if (self.vec2_helper_buf.items.len == cur_poly_start + 1) {
                        // Only one unused point. Remove it.
                        _ = self.vec2_helper_buf.pop();
                    }
                    const data = path.getData(.MoveToRel, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.MoveToRel)) / 4;
                    cur_pt = .{
                        .x = cur_pt.x + data.x,
                        .y = cur_pt.y + data.y,
                    };
                    cur_poly_start = @intCast(u32, self.vec2_helper_buf.items.len);
                    self.vec2_helper_buf.append(cur_pt) catch unreachable;
                },
                .CurveToRel => {
                    const data = path.getData(.CurveToRel, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.CurveToRel)) / 4;

                    last_control_pt = .{
                        .x = cur_pt.x + data.cb_x,
                        .y = cur_pt.y + data.cb_y,
                    };
                    const prev_pt = cur_pt;
                    cur_pt = .{
                        .x = cur_pt.x + data.x,
                        .y = cur_pt.y + data.y,
                    };
                    const c_bez = CubicBez{
                        .x0 = prev_pt.x,
                        .y0 = prev_pt.y,
                        .cx0 = prev_pt.x + data.ca_x,
                        .cy0 = prev_pt.y + data.ca_y,
                        .cx1 = last_control_pt.x,
                        .cy1 = last_control_pt.y,
                        .x1 = cur_pt.x,
                        .y1 = cur_pt.y,
                    };
                    c_bez.flatten(0.5, &self.vec2_helper_buf, &self.qbez_helper_buf);
                    cmd_is_curveto = true;
                },
                .LineTo => {
                    const data = path.getData(.LineTo, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.LineTo)) / 4;

                    cur_pt = .{
                        .x = data.x,
                        .y = data.y,
                    };
                    self.vec2_helper_buf.append(cur_pt) catch unreachable;
                },
                .LineToRel => {
                    const data = path.getData(.LineToRel, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.LineToRel)) / 4;

                    cur_pt = .{
                        .x = cur_pt.x + data.x,
                        .y = cur_pt.y + data.y,
                    };
                    self.vec2_helper_buf.append(cur_pt) catch unreachable;
                },
                .SmoothCurveToRel => {
                    const data = path.getData(.SmoothCurveToRel, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.SmoothCurveToRel)) / 4;

                    var cx0: f32 = undefined;
                    var cy0: f32 = undefined;
                    if (last_cmd_was_curveto) {
                        // Reflection of last control point over current pos.
                        cx0 = cur_pt.x + (cur_pt.x - last_control_pt.x);
                        cy0 = cur_pt.y + (cur_pt.y - last_control_pt.y);
                    } else {
                        cx0 = cur_pt.x;
                        cy0 = cur_pt.y;
                    }
                    last_control_pt = .{
                        .x = cur_pt.x + data.c2_x,
                        .y = cur_pt.y + data.c2_y,
                    };
                    const prev_pt = cur_pt;
                    cur_pt = .{
                        .x = cur_pt.x + data.x,
                        .y = cur_pt.y + data.y,
                    };
                    const c_bez = CubicBez{
                        .x0 = prev_pt.x,
                        .y0 = prev_pt.y,
                        .cx0 = cx0,
                        .cy0 = cy0,
                        .cx1 = last_control_pt.x,
                        .cy1 = last_control_pt.y,
                        .x1 = cur_pt.x,
                        .y1 = cur_pt.y,
                    };
                    c_bez.flatten(0.5, &self.vec2_helper_buf, &self.qbez_helper_buf);
                    cmd_is_curveto = true;
                },
                .VertLineToRel => {
                    const data = path.getData(.VertLineToRel, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.VertLineToRel)) / 4;
                    cur_pt.y += data.y;
                    self.vec2_helper_buf.append(cur_pt) catch unreachable;
                },
                .ClosePath => {
                    // if (fill) {
                    //     // For fills, this is a no-op.
                    // } else {
                    //     // For strokes, this would form a seamless connection to the first point.
                    // }
                },
                else => {
                    stdx.panicFmt("unsupported: {}", .{cmd});
                },
            }
            last_cmd_was_curveto = cmd_is_curveto;
        }

        if (self.vec2_helper_buf.items.len > cur_poly_start + 1) {
            // Push the current polygon.
            self.vec2_slice_helper_buf.append(self.vec2_helper_buf.items[cur_poly_start..]) catch unreachable;
        }
        if (self.vec2_slice_helper_buf.items.len == 0) {
            return;
        }

        for (self.vec2_slice_helper_buf.items) |polygon| {
            var tess = getTess2Handle();
            tess2.tessAddContour(tess, 2, &polygon[0], 8, @intCast(c_int, polygon.len));
            const res = tess2.tessTesselate(tess, tess2.TESS_WINDING_ODD, tess2.TESS_POLYGONS, 3, 2, null);
            if (res == 0) {
                unreachable;
            }

            var gpu_vert: TexShaderVertex = undefined;
            gpu_vert.setColor(self.cur_fill_color);
            const vert_offset_id = self.batcher.mesh.getNextIndexId();
            var nverts = tess2.tessGetVertexCount(tess);
            var verts = tess2.tessGetVertices(tess);
            const nelems = tess2.tessGetElementCount(tess);

            // log.debug("poly: {}, {}, {}", .{polygon.len, nverts, nelems});

            self.setCurrentTexture(self.white_tex);
            self.ensureUnusedBatchCapacity(@intCast(u32, nverts), @intCast(usize, nelems * 3));

            var i: u32 = 0;
            while (i < nverts) : (i += 1) {
                gpu_vert.setXY(verts[i*2], verts[i*2+1]);
                // log.debug("{},{}", .{gpu_vert.pos_x, gpu_vert.pos_y});
                gpu_vert.setUV(0, 0);
                _ = self.batcher.mesh.addVertex(&gpu_vert);
            }
            const elems = tess2.tessGetElements(tess);
            i = 0;
            while (i < nelems) : (i += 1) {
                self.batcher.mesh.addIndex(@intCast(u16, vert_offset_id + elems[i*3+2]));
                self.batcher.mesh.addIndex(@intCast(u16, vert_offset_id + elems[i*3+1]));
                self.batcher.mesh.addIndex(@intCast(u16, vert_offset_id + elems[i*3]));
                // log.debug("idx {}", .{elems[i]});
            }
        }
    }

    pub fn strokeSvgPath(self: *Self, x: f32, y: f32, path: *const svg.SvgPath) void {
        self.drawSvgPath(x, y, path, false);
    }

    fn drawSvgPath(self: *Self, x: f32, y: f32, path: *const svg.SvgPath, fill: bool) void {
        // log.debug("drawSvgPath {} {}", .{path.cmds.len, fill});

        _ = x;
        _ = y;

        // Accumulate polygons.
        self.vec2_helper_buf.clearRetainingCapacity();
        self.vec2_slice_helper_buf.clearRetainingCapacity();
        self.qbez_helper_buf.clearRetainingCapacity();

        var last_cmd_was_curveto = false;
        var last_control_pt = vec2(0, 0);
        var cur_data_idx: u32 = 0;
        var cur_pt = vec2(0, 0);
        var cur_poly_start: u32 = 0;

        for (path.cmds) |cmd| {
            var cmd_is_curveto = false;
            switch (cmd) {
                .MoveTo => {
                    if (self.vec2_helper_buf.items.len > cur_poly_start + 1) {
                        self.vec2_slice_helper_buf.append(self.vec2_helper_buf.items[cur_poly_start..]) catch unreachable;
                    } else if (self.vec2_helper_buf.items.len == cur_poly_start + 1) {
                        // Only one unused point. Remove it.
                        _ = self.vec2_helper_buf.pop();
                    }
                    const data = path.getData(.MoveTo, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.MoveTo)) / 4;
                    cur_pt = .{
                        .x = data.x,
                        .y = data.y,
                    };
                    cur_poly_start = @intCast(u32, self.vec2_helper_buf.items.len);
                    self.vec2_helper_buf.append(cur_pt) catch unreachable;
                },
                .MoveToRel => {
                    if (self.vec2_helper_buf.items.len > cur_poly_start + 1) {
                        self.vec2_slice_helper_buf.append(self.vec2_helper_buf.items[cur_poly_start..]) catch unreachable;
                    } else if (self.vec2_helper_buf.items.len == cur_poly_start + 1) {
                        // Only one unused point. Remove it.
                        _ = self.vec2_helper_buf.pop();
                    }
                    const data = path.getData(.MoveToRel, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.MoveToRel)) / 4;
                    cur_pt = .{
                        .x = cur_pt.x + data.x,
                        .y = cur_pt.y + data.y,
                    };
                    cur_poly_start = @intCast(u32, self.vec2_helper_buf.items.len);
                    self.vec2_helper_buf.append(cur_pt) catch unreachable;
                },
                .CurveToRel => {
                    const data = path.getData(.CurveToRel, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.CurveToRel)) / 4;

                    last_control_pt = .{
                        .x = cur_pt.x + data.cb_x,
                        .y = cur_pt.y + data.cb_y,
                    };
                    const prev_pt = cur_pt;
                    cur_pt = .{
                        .x = cur_pt.x + data.x,
                        .y = cur_pt.y + data.y,
                    };
                    const c_bez = CubicBez{
                        .x0 = prev_pt.x,
                        .y0 = prev_pt.y,
                        .cx0 = prev_pt.x + data.ca_x,
                        .cy0 = prev_pt.y + data.ca_y,
                        .cx1 = last_control_pt.x,
                        .cy1 = last_control_pt.y,
                        .x1 = cur_pt.x,
                        .y1 = cur_pt.y,
                    };
                    c_bez.flatten(0.5, &self.vec2_helper_buf, &self.qbez_helper_buf);
                    cmd_is_curveto = true;
                },
                .LineTo => {
                    const data = path.getData(.LineTo, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.LineTo)) / 4;

                    cur_pt = .{
                        .x = data.x,
                        .y = data.y,
                    };
                    self.vec2_helper_buf.append(cur_pt) catch unreachable;
                },
                .LineToRel => {
                    const data = path.getData(.LineToRel, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.LineToRel)) / 4;

                    cur_pt = .{
                        .x = cur_pt.x + data.x,
                        .y = cur_pt.y + data.y,
                    };
                    self.vec2_helper_buf.append(cur_pt) catch unreachable;
                },
                .SmoothCurveToRel => {
                    const data = path.getData(.SmoothCurveToRel, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.SmoothCurveToRel)) / 4;

                    var cx0: f32 = undefined;
                    var cy0: f32 = undefined;
                    if (last_cmd_was_curveto) {
                        // Reflection of last control point over current pos.
                        cx0 = cur_pt.x + (cur_pt.x - last_control_pt.x);
                        cy0 = cur_pt.y + (cur_pt.y - last_control_pt.y);
                    } else {
                        cx0 = cur_pt.x;
                        cy0 = cur_pt.y;
                    }
                    last_control_pt = .{
                        .x = cur_pt.x + data.c2_x,
                        .y = cur_pt.y + data.c2_y,
                    };
                    const prev_pt = cur_pt;
                    cur_pt = .{
                        .x = cur_pt.x + data.x,
                        .y = cur_pt.y + data.y,
                    };
                    const c_bez = CubicBez{
                        .x0 = prev_pt.x,
                        .y0 = prev_pt.y,
                        .cx0 = cx0,
                        .cy0 = cy0,
                        .cx1 = last_control_pt.x,
                        .cy1 = last_control_pt.y,
                        .x1 = cur_pt.x,
                        .y1 = cur_pt.y,
                    };
                    c_bez.flatten(0.5, &self.vec2_helper_buf, &self.qbez_helper_buf);
                    cmd_is_curveto = true;
                },
                .VertLineToRel => {
                    const data = path.getData(.VertLineToRel, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.VertLineToRel)) / 4;
                    cur_pt.y += data.y;
                    self.vec2_helper_buf.append(cur_pt) catch unreachable;
                },
                .ClosePath => {
                    if (fill) {
                        // For fills, this is a no-op.
                    } else {
                        // For strokes, this would form a seamless connection to the first point.
                    }
                },
                else => {
                    stdx.panicFmt("unsupported: {}", .{cmd});
                },
            }
        //         .VertLineTo => {
        //             const data = path.getData(.VertLineTo, cur_data_idx);
        //             cur_data_idx += @sizeOf(svg.PathCommandData(.VertLineTo)) / 4;
        //             cur_pos.y = data.y;
        //             lyon.lineTo(b, &cur_pos);
        //         },
        //         .CurveTo => {
        //             const data = path.getData(.CurveTo, cur_data_idx);
        //             cur_data_idx += @sizeOf(svg.PathCommandData(.CurveTo)) / 4;
        //             cur_pos.x = data.x;
        //             cur_pos.y = data.y;
        //             last_control_pos.x = data.cb_x;
        //             last_control_pos.y = data.cb_y;
        //             cmd_is_curveto = true;
        //             lyon.cubicBezierTo(b, &pt(data.ca_x, data.ca_y), &last_control_pos, &cur_pos);
        //         },
        //         .SmoothCurveTo => {
        //             const data = path.getData(.SmoothCurveTo, cur_data_idx);
        //             cur_data_idx += @sizeOf(svg.PathCommandData(.SmoothCurveTo)) / 4;

        //             // Reflection of last control point over current pos.
        //             var c1_x: f32 = undefined;
        //             var c1_y: f32 = undefined;
        //             if (last_cmd_was_curveto) {
        //                 c1_x = cur_pos.x + (cur_pos.x - last_control_pos.x);
        //                 c1_y = cur_pos.y + (cur_pos.y - last_control_pos.y);
        //             } else {
        //                 c1_x = cur_pos.x;
        //                 c1_y = cur_pos.y;
        //             }

        //             cur_pos.x = data.x;
        //             cur_pos.y = data.y;
        //             last_control_pos.x = data.c2_x;
        //             last_control_pos.y = data.c2_y;
        //             cmd_is_curveto = true;
        //             lyon.cubicBezierTo(b, &pt(c1_x, c1_y), &last_control_pos, &cur_pos);
        //         },
        //     }
            last_cmd_was_curveto = cmd_is_curveto;
        }

        if (self.vec2_helper_buf.items.len > cur_poly_start + 1) {
            // Push the current polygon.
            self.vec2_slice_helper_buf.append(self.vec2_helper_buf.items[cur_poly_start..]) catch unreachable;
        }
        if (self.vec2_slice_helper_buf.items.len == 0) {
            return;
        }

        if (fill) {
            // dumpPolygons(self.alloc, self.vec2_slice_helper_buf.items);
            self.tessellator.clearBuffers();
            self.tessellator.triangulatePolygons(self.vec2_slice_helper_buf.items);
            self.setCurrentTexture(self.white_tex);
            const out_verts = self.tessellator.out_verts.items;
            const out_idxes = self.tessellator.out_idxes.items;
            self.ensureUnusedBatchCapacity(out_verts.len, out_idxes.len);
            self.batcher.pushVertIdxBatch(out_verts, out_idxes, self.cur_fill_color);
        } else {
            unreachable;
        //     var data = lyon.buildStroke(b, self.cur_line_width);
        //     self.setCurrentTexture(self.white_tex);
        //     self.pushLyonVertexData(&data, self.cur_stroke_color);
        }
    }

    fn drawSvgPathLyon(self: *Self, x: f32, y: f32, path: *const svg.SvgPath, fill: bool) void {
        // log.debug("drawSvgPath {}", .{path.cmds.len});
        _ = x;
        _ = y;
        const b = lyon.initBuilder();
        var cur_pos = pt(0, 0);
        var cur_data_idx: u32 = 0;
        var last_control_pos = pt(0, 0);
        var cur_path_ended = true;
        var last_cmd_was_curveto = false;

        for (path.cmds) |it| {
            var cmd_is_curveto = false;
            switch (it) {
                .MoveTo => {
                    if (!cur_path_ended) {
                        // End previous subpath.
                        lyon.end(b, false);
                    }
                    // log.debug("lyon begin", .{});
                    const data = path.getData(.MoveTo, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.MoveTo)) / 4;
                    cur_pos.x = data.x;
                    cur_pos.y = data.y;
                    lyon.begin(b, &cur_pos);
                    cur_path_ended = false;
                },
                .MoveToRel => {
                    if (!cur_path_ended) {
                        // End previous subpath.
                        lyon.end(b, false);
                    }
                    const data = path.getData(.MoveToRel, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.MoveToRel)) / 4;
                    cur_pos.x += data.x;
                    cur_pos.y += data.y;
                    lyon.begin(b, &cur_pos);
                    cur_path_ended = false;
                },
                .VertLineTo => {
                    const data = path.getData(.VertLineTo, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.VertLineTo)) / 4;
                    cur_pos.y = data.y;
                    lyon.lineTo(b, &cur_pos);
                },
                .VertLineToRel => {
                    const data = path.getData(.VertLineToRel, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.VertLineToRel)) / 4;
                    cur_pos.y += data.y;
                    lyon.lineTo(b, &cur_pos);
                },
                .LineTo => {
                    const data = path.getData(.LineTo, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.LineTo)) / 4;
                    cur_pos.x = data.x;
                    cur_pos.y = data.y;
                    lyon.lineTo(b, &cur_pos);
                },
                .LineToRel => {
                    const data = path.getData(.LineToRel, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.LineToRel)) / 4;
                    cur_pos.x += data.x;
                    cur_pos.y += data.y;
                    lyon.lineTo(b, &cur_pos);
                },
                .CurveTo => {
                    const data = path.getData(.CurveTo, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.CurveTo)) / 4;
                    cur_pos.x = data.x;
                    cur_pos.y = data.y;
                    last_control_pos.x = data.cb_x;
                    last_control_pos.y = data.cb_y;
                    cmd_is_curveto = true;
                    lyon.cubicBezierTo(b, &pt(data.ca_x, data.ca_y), &last_control_pos, &cur_pos);
                },
                .CurveToRel => {
                    const data = path.getData(.CurveToRel, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.CurveToRel)) / 4;
                    const prev_x = cur_pos.x;
                    const prev_y = cur_pos.y;
                    cur_pos.x += data.x;
                    cur_pos.y += data.y;
                    last_control_pos.x = prev_x + data.cb_x;
                    last_control_pos.y = prev_y + data.cb_y;
                    cmd_is_curveto = true;
                    lyon.cubicBezierTo(b, &pt(prev_x + data.ca_x, prev_y + data.ca_y), &last_control_pos, &cur_pos);
                },
                .SmoothCurveTo => {
                    const data = path.getData(.SmoothCurveTo, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.SmoothCurveTo)) / 4;

                    // Reflection of last control point over current pos.
                    var c1_x: f32 = undefined;
                    var c1_y: f32 = undefined;
                    if (last_cmd_was_curveto) {
                        c1_x = cur_pos.x + (cur_pos.x - last_control_pos.x);
                        c1_y = cur_pos.y + (cur_pos.y - last_control_pos.y);
                    } else {
                        c1_x = cur_pos.x;
                        c1_y = cur_pos.y;
                    }

                    cur_pos.x = data.x;
                    cur_pos.y = data.y;
                    last_control_pos.x = data.c2_x;
                    last_control_pos.y = data.c2_y;
                    cmd_is_curveto = true;
                    lyon.cubicBezierTo(b, &pt(c1_x, c1_y), &last_control_pos, &cur_pos);
                },
                .SmoothCurveToRel => {
                    const data = path.getData(.SmoothCurveToRel, cur_data_idx);
                    cur_data_idx += @sizeOf(svg.PathCommandData(.SmoothCurveToRel)) / 4;
                    const prev_x = cur_pos.x;
                    const prev_y = cur_pos.y;

                    var c1_x: f32 = undefined;
                    var c1_y: f32 = undefined;
                    if (last_cmd_was_curveto) {
                        // Reflection of last control point over current pos.
                        c1_x = cur_pos.x + (cur_pos.x - last_control_pos.x);
                        c1_y = cur_pos.y + (cur_pos.y - last_control_pos.y);
                    } else {
                        c1_x = cur_pos.x;
                        c1_y = cur_pos.y;
                    }

                    cur_pos.x += data.x;
                    cur_pos.y += data.y;
                    last_control_pos.x = prev_x + data.c2_x;
                    last_control_pos.y = prev_y + data.c2_y;
                    cmd_is_curveto = true;
                    lyon.cubicBezierTo(b, &pt(c1_x, c1_y), &last_control_pos, &cur_pos);
                },
                .ClosePath => {
                    lyon.close(b);
                    cur_path_ended = true;
                },
            }
            last_cmd_was_curveto = cmd_is_curveto;
        }
        if (fill) {
            var data = lyon.buildFill(b);
            self.setCurrentTexture(self.white_tex);
            self.pushLyonVertexData(&data, self.cur_fill_color);
        } else {
            var data = lyon.buildStroke(b, self.cur_line_width);
            self.setCurrentTexture(self.white_tex);
            self.pushLyonVertexData(&data, self.cur_stroke_color);
        }
    }

    /// Points of front face is in ccw order.
    pub fn fillTriangle3D(self: *Self, x1: f32, y1: f32, z1: f32, x2: f32, y2: f32, z2: f32, x3: f32, y3: f32, z3: f32) void {
        self.batcher.beginTex3D(self.white_tex);
        self.ensureUnusedBatchCapacity(3, 3);

        var vert: TexShaderVertex = undefined;
        vert.setColor(self.cur_fill_color);
        vert.setUV(0, 0); // Don't map uvs for now.

        const start_idx = self.batcher.mesh.getNextIndexId();
        vert.setXYZ(x1, y1, z1);
        self.batcher.mesh.addVertex(&vert);
        vert.setXYZ(x2, y2, z2);
        self.batcher.mesh.addVertex(&vert);
        vert.setXYZ(x3, y3, z3);
        self.batcher.mesh.addVertex(&vert);
        self.batcher.mesh.addTriangle(start_idx, start_idx + 1, start_idx + 2);
    }

    pub fn fillTriangle(self: *Self, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32) void {
        self.setCurrentTexture(self.white_tex);
        self.ensureUnusedBatchCapacity(3, 3);

        var vert: TexShaderVertex = undefined;
        vert.setColor(self.cur_fill_color);
        vert.setUV(0, 0); // Don't map uvs for now.

        const start_idx = self.batcher.mesh.getNextIndexId();
        vert.setXY(x1, y1);
        self.batcher.mesh.addVertex(&vert);
        vert.setXY(x2, y2);
        self.batcher.mesh.addVertex(&vert);
        vert.setXY(x3, y3);
        self.batcher.mesh.addVertex(&vert);
        self.batcher.mesh.addTriangle(start_idx, start_idx + 1, start_idx + 2);
    }

    /// Assumes pts are in ccw order.
    pub fn fillConvexPolygon(self: *Self, pts: []const Vec2) void {
        self.setCurrentTexture(self.white_tex);
        self.ensureUnusedBatchCapacity(pts.len, (pts.len - 2) * 3);

        var vert: TexShaderVertex = undefined;
        vert.setColor(self.cur_fill_color);
        vert.setUV(0, 0); // Don't map uvs for now.

        const start_idx = self.batcher.mesh.getNextIndexId();

        // Add first two vertices.
        vert.setXY(pts[0].x, pts[0].y);
        self.batcher.mesh.addVertex(&vert);
        vert.setXY(pts[1].x, pts[1].y);
        self.batcher.mesh.addVertex(&vert);

        var i: u16 = 2;
        while (i < pts.len) : (i += 1) {
            vert.setXY(pts[i].x, pts[i].y);
            self.batcher.mesh.addVertex(&vert);
            self.batcher.mesh.addTriangle(start_idx, start_idx + i - 1, start_idx + i);
        }
    }

    pub fn fillPolygon(self: *Self, pts: []const Vec2) void {
        self.tessellator.clearBuffers();
        self.tessellator.triangulatePolygon(pts);
        self.setCurrentTexture(self.white_tex);
        const out_verts = self.tessellator.out_verts.items;
        const out_idxes = self.tessellator.out_idxes.items;
        self.ensureUnusedBatchCapacity(out_verts.len, out_idxes.len);
        self.batcher.pushVertIdxBatch(out_verts, out_idxes, self.cur_fill_color);
    }

    pub fn fillPolygonLyon(self: *Self, pts: []const Vec2) void {
        const b = lyon.initBuilder();
        lyon.addPolygon(b, pts, true);
        var data = lyon.buildFill(b);

        self.setCurrentTexture(self.white_tex);
        self.pushLyonVertexData(&data, self.cur_fill_color);
    }

    pub fn fillPolygonTess2(self: *Self, pts: []const Vec2) void {
        var tess = getTess2Handle();
        tess2.tessAddContour(tess, 2, &pts[0], 0, @intCast(c_int, pts.len));
        const res = tess2.tessTesselate(tess, tess2.TESS_WINDING_ODD, tess2.TESS_POLYGONS, 3, 2, null);
        if (res == 0) {
            unreachable;
        }

        var gpu_vert: TexShaderVertex = undefined;
        gpu_vert.setColor(self.cur_fill_color);
        const vert_offset_id = self.batcher.mesh.getNextIndexId();
        var nverts = tess2.tessGetVertexCount(tess);
        var verts = tess2.tessGetVertices(tess);
        const nelems = tess2.tessGetElementCount(tess);

        self.ensureUnusedBatchCapacity(@intCast(u32, nverts), @intCast(usize, nelems * 3));

        var i: u32 = 0;
        while (i < nverts) : (i += 1) {
            gpu_vert.setXY(verts[i*2], verts[i*2+1]);
            gpu_vert.setUV(0, 0);
            _ = self.batcher.mesh.addVertex(&gpu_vert);
        }
        const elems = tess2.tessGetElements(tess);
        i = 0;
        while (i < nelems) : (i += 1) {
            self.batcher.mesh.addIndex(@intCast(u16, vert_offset_id + elems[i*3+2]));
            self.batcher.mesh.addIndex(@intCast(u16, vert_offset_id + elems[i*3+1]));
            self.batcher.mesh.addIndex(@intCast(u16, vert_offset_id + elems[i*3]));
        }
    }

    pub fn drawPolygon(self: *Self, pts: []const Vec2) void {
        _ = self;
        _ = pts;
        self.batcher.beginTex(self.white_tex);
        // TODO: Implement this.
    }

    pub fn drawPolygonLyon(self: *Self, pts: []const Vec2) void {
        self.batcher.beginTex(self.white_tex);
        const b = lyon.initBuilder();
        lyon.addPolygon(b, pts, true);
        var data = lyon.buildStroke(b, self.cur_line_width);

        self.pushLyonVertexData(&data, self.cur_stroke_color);
    }

    pub fn drawSubImage(self: *Self, src_x: f32, src_y: f32, src_width: f32, src_height: f32, x: f32, y: f32, width: f32, height: f32, image_id: ImageId) void {
        const img = self.image_store.images.get(image_id);
        self.batcher.beginTex(image.ImageDesc{ .image_id = image_id, .tex_id = img.tex_id });
        self.ensureUnusedBatchCapacity(4, 6);

        var vert: TexShaderVertex = undefined;
        vert.setColor(Color.White);

        const start_idx = self.batcher.mesh.getNextIndexId();

        const u_start = src_x / width;
        const u_end = (src_x + src_width) / width;
        const v_start = src_y / height;
        const v_end = (src_y + src_height) / height;

        // top left
        vert.setXY(x, y);
        vert.setUV(u_start, v_start);
        self.batcher.mesh.addVertex(&vert);

        // top right
        vert.setXY(x + width, y);
        vert.setUV(u_end, v_start);
        self.batcher.mesh.addVertex(&vert);

        // bottom right
        vert.setXY(x + width, y + height);
        vert.setUV(u_end, v_end);
        self.batcher.mesh.addVertex(&vert);

        // bottom left
        vert.setXY(x, y + height);
        vert.setUV(u_start, v_end);
        self.batcher.mesh.addVertex(&vert);

        // add rect
        self.batcher.mesh.addQuad(start_idx, start_idx + 1, start_idx + 2, start_idx + 3);
    }

    pub fn drawImageSized(self: *Self, x: f32, y: f32, width: f32, height: f32, image_id: ImageId) void {
        const img = self.image_store.images.getNoCheck(image_id);
        self.batcher.beginTex(image.ImageTex{ .image_id = image_id, .tex_id = img.tex_id });
        self.ensureUnusedBatchCapacity(4, 6);

        var vert: TexShaderVertex = undefined;
        vert.setColor(Color.White);

        const start_idx = self.batcher.mesh.getNextIndexId();

        // top left
        vert.setXY(x, y);
        vert.setUV(0, 0);
        self.batcher.mesh.addVertex(&vert);

        // top right
        vert.setXY(x + width, y);
        vert.setUV(1, 0);
        self.batcher.mesh.addVertex(&vert);

        // bottom right
        vert.setXY(x + width, y + height);
        vert.setUV(1, 1);
        self.batcher.mesh.addVertex(&vert);

        // bottom left
        vert.setXY(x, y + height);
        vert.setUV(0, 1);
        self.batcher.mesh.addVertex(&vert);

        // add rect
        self.batcher.mesh.addQuad(start_idx, start_idx + 1, start_idx + 2, start_idx + 3);
    }

    pub fn drawImage(self: *Self, x: f32, y: f32, image_id: ImageId) void {
        const img = self.image_store.images.getNoCheck(image_id);
        self.batcher.beginTex(image.ImageTex{ .image_id = image_id, .tex_id = img.tex_id });
        self.ensureUnusedBatchCapacity(4, 6);

        var vert: TexShaderVertex = undefined;
        vert.setColor(Color.White);

        const start_idx = self.batcher.mesh.getNextIndexId();

        // top left
        vert.setXY(x, y);
        vert.setUV(0, 0);
        self.batcher.mesh.addVertex(&vert);

        // top right
        vert.setXY(x + @intToFloat(f32, img.width), y);
        vert.setUV(1, 0);
        self.batcher.mesh.addVertex(&vert);

        // bottom right
        vert.setXY(x + @intToFloat(f32, img.width), y + @intToFloat(f32, img.height));
        vert.setUV(1, 1);
        self.batcher.mesh.addVertex(&vert);

        // bottom left
        vert.setXY(x, y + @intToFloat(f32, img.height));
        vert.setUV(0, 1);
        self.batcher.mesh.addVertex(&vert);

        // add rect
        self.batcher.mesh.addQuad(start_idx, start_idx + 1, start_idx + 2, start_idx + 3);
    }

    /// Binds an image to the write buffer. 
    pub fn bindImageBuffer(self: *Self, image_id: ImageId) void {
        var img = self.image_store.images.getPtrNoCheck(image_id);
        if (img.fbo_id == null) {
            img.fbo_id = self.createTextureFramebuffer(img.tex_id);
        }
        gl.bindFramebuffer(gl.GL_FRAMEBUFFER, img.fbo_id.?);
        gl.viewport(0, 0, @intCast(c_int, img.width), @intCast(c_int, img.height));
        self.cur_proj_transform = graphics.initTextureProjection(@intToFloat(f32, img.width), @intToFloat(f32, img.height));
        self.view_transform = Transform.initIdentity();
        const mvp = self.view_transform.getAppliedTransform(self.cur_proj_transform);
        self.batcher.beginMvp(mvp);
    }

    fn createTextureFramebuffer(self: Self, tex_id: gl.GLuint) gl.GLuint {
        _ = self;
        var fbo_id: gl.GLuint = 0;
        gl.genFramebuffers(1, &fbo_id);
        gl.bindFramebuffer(gl.GL_FRAMEBUFFER, fbo_id);

        gl.bindTexture(gl.GL_TEXTURE_2D, tex_id);
        gl.framebufferTexture2D(gl.GL_FRAMEBUFFER, gl.GL_COLOR_ATTACHMENT0, gl.GL_TEXTURE_2D, tex_id, 0);
        const status = gl.checkFramebufferStatus(gl.GL_FRAMEBUFFER);
        if (status != gl.GL_FRAMEBUFFER_COMPLETE) {
            log.debug("unexpected status: {}", .{status});
            unreachable;
        }
        return fbo_id;
    }

    pub fn beginFrameVK(self: *Self, buf_width: u32, buf_height: u32, image_idx: u32, frame_idx: u32) void {
        self.cur_buf_width = buf_width;
        self.cur_buf_height = buf_height;
        self.inner.cur_cmd_buf = self.inner.ctx.cmd_bufs[image_idx];
        self.batcher.resetStateVK(self.white_tex, image_idx, frame_idx, self.clear_color);

        self.cur_clip_rect = .{
            .x = 0,
            .y = 0,
            .width = @intToFloat(f32, buf_width),
            .height = @intToFloat(f32, buf_height),
        };
        self.cur_scissors = false;

        self.clipRectCmd(self.cur_clip_rect);
    }

    /// Begin frame sets up the context before any other draw call.
    /// This should be agnostic to the view port dimensions so this context can be reused by different windows.
    pub fn beginFrame(self: *Self, buf_width: u32, buf_height: u32, custom_fbo: gl.GLuint) void {
        // log.debug("beginFrame", .{});

        self.cur_buf_width = buf_width;
        self.cur_buf_height = buf_height;

        // TODO: Viewport only needs to be set on window resize or multiple windows are active.
        gl.viewport(0, 0, @intCast(c_int, buf_width), @intCast(c_int, buf_height));

        self.batcher.resetState(self.white_tex);

        // Scissor affects glClear so reset it first.
        self.cur_clip_rect = .{
            .x = 0,
            .y = 0,
            .width = @intToFloat(f32, buf_width),
            .height = @intToFloat(f32, buf_height),
        };
        self.cur_scissors = false;
        gl.disable(gl.GL_SCISSOR_TEST);

        if (custom_fbo == 0) {
            // This clears the main framebuffer that is swapped to window.
            gl.bindFramebuffer(gl.GL_DRAW_FRAMEBUFFER, 0);
            gl.clear(gl.GL_COLOR_BUFFER_BIT);
        } else {
            // Set the frame buffer we are drawing to.
            gl.bindFramebuffer(gl.GL_DRAW_FRAMEBUFFER, custom_fbo);
            // Clears the custom frame buffer.
            gl.clear(gl.GL_COLOR_BUFFER_BIT);
        }

        // Straight alpha by default.
        self.setBlendMode(.StraightAlpha);
    }

    pub fn endFrameVK(self: *Self) void {
        self.endCmd();
        self.batcher.endFrameVK();
        self.image_store.processRemovals();
    }

    pub fn endFrame(self: *Self, buf_width: u32, buf_height: u32, custom_fbo: gl.GLuint) void {
        // log.debug("endFrame", .{});
        self.endCmd();
        if (custom_fbo != 0) {
            // If we were drawing to custom framebuffer such as msaa buffer, then blit the custom buffer into the default ogl buffer.
            gl.bindFramebuffer(gl.GL_READ_FRAMEBUFFER, custom_fbo);
            gl.bindFramebuffer(gl.GL_DRAW_FRAMEBUFFER, 0);
            // blit's filter is only used when the sizes between src and dst buffers are different.
            gl.blitFramebuffer(0, 0, @intCast(c_int, buf_width), @intCast(c_int, buf_height), 0, 0, @intCast(c_int, buf_width), @intCast(c_int, buf_height), gl.GL_COLOR_BUFFER_BIT, gl.GL_NEAREST);
        }
    }

    pub fn setCamera(self: *Self, cam: graphics.Camera) void {
        self.endCmd();
        self.cur_proj_transform = cam.proj_transform;
        self.view_transform = cam.view_transform;
        self.batcher.mvp = self.view_transform.getAppliedTransform(self.cur_proj_transform);
    }

    pub fn translate(self: *Self, x: f32, y: f32) void {
        self.view_transform.translate(x, y);
        const mvp = self.view_transform.getAppliedTransform(self.cur_proj_transform);
        self.batcher.beginMvp(mvp);
    }

    pub fn translate3D(self: *Self, x: f32, y: f32, z: f32) void {
        self.view_transform.translate3D(x, y, z);
        const mvp = self.view_transform.getAppliedTransform(self.cur_proj_transform);
        self.batcher.beginMvp(mvp);
    }

    pub fn scale(self: *Self, x: f32, y: f32) void {
        self.view_transform.scale(x, y);
        const mvp = self.view_transform.getAppliedTransform(self.cur_proj_transform);
        self.batcher.beginMvp(mvp);
    }

    pub fn rotateZ(self: *Self, rad: f32) void {
        self.view_transform.rotateZ(rad);
        const mvp = self.view_transform.getAppliedTransform(self.cur_proj_transform);
        self.batcher.beginMvp(mvp);
    }

    pub fn rotateX(self: *Self, rad: f32) void {
        self.view_transform.rotateX(rad);
        const mvp = self.view_transform.getAppliedTransform(self.cur_proj_transform);
        self.batcher.beginMvp(mvp);
    }

    pub fn rotateY(self: *Self, rad: f32) void {
        self.view_transform.rotateY(rad);
        const mvp = self.view_transform.getAppliedTransform(self.cur_proj_transform);
        self.batcher.beginMvp(mvp);
    }

    // GL Only.
    pub fn setBlendModeCustom(self: *Self, src: gl.GLenum, dst: gl.GLenum, eq: gl.GLenum) void {
        _ = self;
        gl.blendFunc(src, dst);
        gl.blendEquation(eq);
    }

    // TODO: Implement this in Vulkan.
    pub fn setBlendMode(self: *Self, mode: BlendMode) void {
        if (self.cur_blend_mode != mode) {
            self.endCmd();
            switch (mode) {
                .StraightAlpha => gl.blendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA),
                .Add, .Glow => {
                    gl.blendFunc(gl.GL_ONE, gl.GL_ONE);
                    gl.blendEquation(gl.GL_FUNC_ADD);
                },
                .Subtract => {
                    gl.blendFunc(gl.GL_ONE, gl.GL_ONE);
                    gl.blendEquation(gl.GL_FUNC_SUBTRACT);
                },
                .Multiplied => {
                    gl.blendFunc(gl.GL_DST_COLOR, gl.GL_ONE_MINUS_SRC_ALPHA);
                    gl.blendEquation(gl.GL_FUNC_ADD);
                },
                .Opaque => {
                    gl.blendFunc(gl.GL_ONE, gl.GL_ZERO);
                    gl.blendEquation(gl.GL_FUNC_ADD);
                },
                .Additive => {
                    gl.blendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE);
                    gl.blendEquation(gl.GL_FUNC_ADD);
                },
                .PremultipliedAlpha => {
                    gl.blendFunc(gl.GL_ONE, gl.GL_ONE_MINUS_SRC_ALPHA);
                    gl.blendEquation(gl.GL_FUNC_ADD);
                },
                else => @panic("unsupported"),
            }
            self.cur_blend_mode = mode;
        }
    }

    pub fn endCmd(self: *Self) void {
        self.batcher.endCmd();
    }

    pub fn updateTextureData(self: *const Self, img: image.Image, buf: []const u8) void {
        switch (Backend) {
            .OpenGL => {
                gl.activeTexture(gl.GL_TEXTURE0 + 0);
                const gl_tex_id = self.image_store.getTexture(img.tex_id).inner.tex_id;
                gl.bindTexture(gl.GL_TEXTURE_2D, gl_tex_id);
                gl.texSubImage2D(gl.GL_TEXTURE_2D, 0, 0, 0, @intCast(c_int, img.width), @intCast(c_int, img.height), gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, buf.ptr);
                gl.bindTexture(gl.GL_TEXTURE_2D, 0);
            },
            .Vulkan => {
                const ctx = self.inner.ctx;

                var staging_buf: vk.VkBuffer = undefined;
                var staging_buf_mem: vk.VkDeviceMemory = undefined;

                const size = @intCast(u32, buf.len);
                gvk.buffer.createBuffer(ctx.physical, ctx.device, size, vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &staging_buf, &staging_buf_mem);

                // Copy to gpu.
                var gpu_data: ?*anyopaque = null;
                var res = vk.mapMemory(ctx.device, staging_buf_mem, 0, size, 0, &gpu_data);
                vk.assertSuccess(res);
                std.mem.copy(u8, @ptrCast([*]u8, gpu_data)[0..size], buf);
                vk.unmapMemory(ctx.device, staging_buf_mem);

                // Transition to transfer dst layout.
                ctx.transitionImageLayout(img.inner.image, vk.VK_FORMAT_R8G8B8A8_SRGB, vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
                ctx.copyBufferToImage(staging_buf, img.inner.image, img.width, img.height);
                // Transition to shader access layout.
                ctx.transitionImageLayout(img.inner.image, vk.VK_FORMAT_R8G8B8A8_SRGB, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);

                // Cleanup.
                vk.destroyBuffer(ctx.device, staging_buf, null);
                vk.freeMemory(ctx.device, staging_buf_mem, null);
            },
            else => {},
        }
    }
};

const DrawState = struct {
    clip_rect: geom.Rect,
    use_scissors: bool,
    blend_mode: BlendMode,
    view_transform: Transform,
};

fn dumpPolygons(alloc: std.mem.Allocator, polys: []const []const Vec2) void {
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    const writer = buf.writer();

    for (polys) |poly, i| {
        std.fmt.format(writer, "polygon {} ", .{i}) catch unreachable;
        for (poly) |pt_| {
            std.fmt.format(writer, "{d:.2}, {d:.2},", .{pt_.x, pt_.y}) catch unreachable;
        }
        std.fmt.format(writer, "\n", .{}) catch unreachable;
    }

    log.debug("{s}", .{buf.items});
}

var tess_: ?*tess2.TESStesselator = null;

fn getTess2Handle() *tess2.TESStesselator {
    if (tess_ == null) {
        tess_ = tess2.tessNewTess(null);
    }
    return tess_.?;
}