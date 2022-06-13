const std = @import("std");
const builtin = @import("builtin");
const IsWasm = builtin.target.isWasm();
const stdx = @import("stdx");
const fatal = stdx.fatal;
const platform = @import("platform");
const graphics = @import("graphics");
const Transform = graphics.Transform;
const Color = graphics.Color;
const ui = @import("ui");
const Row = ui.widgets.Row;
const Text = ui.widgets.Text;
const TextButton = ui.widgets.TextButton;
const Padding = ui.widgets.Padding;
const Center = ui.widgets.Center;
const Column = ui.widgets.Column;
const ColorPicker = ui.widgets.ColorPicker;
const Sized = ui.widgets.Sized;

const helper = @import("helper.zig");
const log = stdx.log.scoped(.main);

var app: helper.App = undefined;
var main_cam: graphics.Camera = undefined;
var cam_mod: graphics.CameraModule = undefined;

const animated_tri = @embedFile("../../examples/assets/models/animated_triangle.gltf");
var animated_tri_node: graphics.GLTFnode = undefined;
var animated_tri_mesh: graphics.AnimatedMesh = undefined;

var ui_mod: ui.Module = undefined;
var app_root: *App = undefined;

const box = @embedFile("../../examples/assets/models/box.gltf");
var box_node: graphics.GLTFnode = undefined;

const duck = @embedFile("../../examples/assets/models/duck.gltf");
var duck_node: graphics.GLTFnode = undefined;

pub const App = struct {
    box_color: Color,
    duck_color: Color,

    const Self = @This();

    pub fn init(self: *Self, _: *ui.InitContext) void {
        self.box_color = Color.Blue;
        self.duck_color = Color.Yellow;
    }

    pub fn build(self: *Self, c: *ui.BuildContext) ui.FrameId {
        const S = struct {
            fn onBoxColorPreview(self_: *Self, color: Color) void {
                self_.box_color = color;
            }

            fn onBoxColor(self_: *Self, color: Color, save: bool) void {
                _ = save;
                self_.box_color = color;
            }

            fn onDuckColorPreview(self_: *Self, color: Color) void {
                self_.duck_color = color;
            }

            fn onDuckColor(self_: *Self, color: Color, save: bool) void {
                _ = save;
                self_.duck_color = color;
            }
        };

        return c.decl(Sized, .{
            .width = 250,
            .child = c.decl(Column, .{
                .expand = false,
                .children = c.list(.{
                    c.decl(ColorPicker, .{
                        .label = "Box Color",
                        .init_val = self.box_color,
                        .onPreviewChange = c.funcExt(self, S.onBoxColorPreview),
                        .onResult = c.funcExt(self, S.onBoxColor),
                    }),
                    c.decl(ColorPicker, .{
                        .label = "Duck Color",
                        .init_val = self.duck_color,
                        .onPreviewChange = c.funcExt(self, S.onDuckColorPreview),
                        .onResult = c.funcExt(self, S.onDuckColor),
                    }),
                }),
            }),
        });
    }
};

pub fn main() !void {
    // This is the app loop for desktop. For web/wasm see wasm exports below.
    app.init("3d");
    defer app.deinit();

    const alloc = app.alloc;

    ui_mod.init(alloc, app.gctx);
    ui_mod.addInputHandlers(&app.dispatcher);
    defer ui_mod.deinit();

    // Load models.
    var box_h = try app.gctx.loadGLTFandBuffers(alloc, box, .{});
    defer box_h.deinit(alloc);
    box_node = try box_h.loadNode(alloc, 0);
    defer box_node.deinit(app.alloc);

    var duck_h = try app.gctx.loadGLTFandBuffers(alloc, duck, .{});
    defer duck_h.deinit(alloc);
    duck_node = try duck_h.loadNode(app.alloc, 0);
    defer duck_node.deinit(app.alloc);

    var animated_tri_h = try app.gctx.loadGLTFandBuffers(alloc, animated_tri, .{});
    defer animated_tri_h.deinit(alloc);
    animated_tri_node = try animated_tri_h.loadNode(app.alloc, 0);
    defer animated_tri_node.deinit(app.alloc);
    animated_tri_mesh = graphics.AnimatedMesh.init(animated_tri_node);

    const aspect = app.win.getAspectRatio();
    main_cam.initPerspective3D(60, aspect, 0.1, 1000);
    main_cam.moveForward(90);
    main_cam.moveUp(10);
    main_cam.setRotation(0, 0);
    cam_mod.init(&main_cam, &app.dispatcher);

    // Update ui once to bind user root.
    const ui_width = @intToFloat(f32, app.win.getWidth());
    const ui_height = @intToFloat(f32, app.win.getHeight());
    ui_mod.update(0, {}, buildRoot, ui_width, ui_height) catch unreachable;
    app_root = ui_mod.getUserRoot(App).?;

    app.runEventLoop(update);
}

fn buildRoot(_: void, c: *ui.BuildContext) ui.FrameId {
    return c.decl(App, .{});
}

fn update(delta_ms: f32) void {
    cam_mod.update(delta_ms);

    // Render 3D scene.
    const gctx = app.gctx;
    gctx.setCamera(main_cam);

    gctx.drawPlane();

    gctx.setFillColor(Color.Red);
    gctx.fillTriangle3D(0, 0, 0, 20, 0, 0, 0, 20, 0);

    var box_xform = Transform.initIdentity();
    box_xform.translate3D(-1, 1, 0);
    box_xform.scale3D(20, 20, 20);
    gctx.setFillColor(app_root.box_color);
    gctx.fillMesh3D(box_xform, box_node.verts, box_node.indexes);
    gctx.setStrokeColor(Color.Black);
    gctx.strokeMesh3D(box_xform, box_node.verts, box_node.indexes);

    var duck_xform = Transform.initIdentity();
    duck_xform.translate3D(-150, 0, 0);
    gctx.setFillColor(app_root.duck_color);
    gctx.fillMesh3D(duck_xform, duck_node.verts, duck_node.indexes);
    gctx.setStrokeColor(Color.Black);
    gctx.strokeMesh3D(duck_xform, duck_node.verts, duck_node.indexes);

    var animated_tri_xform = Transform.initIdentity();
    animated_tri_xform.scale3D(20, 20, 20);
    animated_tri_xform.rotateY(std.math.pi);
    animated_tri_xform.translate3D(50, 50, 0);
    gctx.setFillColor(Color.Gray);

    animated_tri_mesh.update(delta_ms);
    gctx.fillAnimatedMesh3D(animated_tri_xform, animated_tri_mesh);

    // Render ui.
    gctx.setCamera(app.cam);
    gctx.setFillColor(Color.White);
    gctx.fillTextFmt(10, 710, "cam pos: ({d:.1},{d:.1},{d:.1})", .{main_cam.world_pos.x, main_cam.world_pos.y, main_cam.world_pos.z});
    gctx.fillTextFmt(10, 730, "forward: ({d:.1},{d:.1},{d:.1})", .{main_cam.forward_nvec.x, main_cam.forward_nvec.y, main_cam.forward_nvec.z});
    gctx.fillTextFmt(10, 750, "up: ({d:.1},{d:.1},{d:.1})", .{main_cam.up_nvec.x, main_cam.up_nvec.y, main_cam.up_nvec.z});
    gctx.fillTextFmt(10, 770, "right: ({d:.1},{d:.1},{d:.1})", .{main_cam.right_nvec.x, main_cam.right_nvec.y, main_cam.right_nvec.z});
    const ui_width = @intToFloat(f32, app.win.getWidth());
    const ui_height = @intToFloat(f32, app.win.getHeight());
    ui_mod.updateAndRender(delta_ms, {}, buildRoot, ui_width, ui_height) catch unreachable;
}

pub usingnamespace if (IsWasm) struct {
    export fn wasmInit() *const u8 {
        return helper.wasmInit(&app, "Counter");
    }

    export fn wasmUpdate(cur_time_ms: f64, input_buffer_len: u32) *const u8 {
        return helper.wasmUpdate(cur_time_ms, input_buffer_len, &app, update);
    }

    /// Not that useful since it's a long lived process in the browser.
    export fn wasmDeinit() void {
        app.deinit();
        stdx.wasm.deinit();
    }
} else struct {};