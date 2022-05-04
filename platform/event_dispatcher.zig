const std = @import("std");
const stdx = @import("stdx");
const builtin = @import("builtin");
const platform = @import("platform.zig");
const KeyCode = platform.KeyCode;
const KeyDownEvent = platform.KeyDownEvent;
const KeyUpEvent = platform.KeyUpEvent;
const MouseButton = platform.MouseButton;
const MouseDownEvent = platform.MouseDownEvent;
const MouseUpEvent = platform.MouseUpEvent;
const MouseMoveEvent = platform.MouseMoveEvent;
const MouseScrollEvent = platform.MouseScrollEvent;
const WindowResizeEvent = platform.WindowResizeEvent;
const sdl = @import("sdl");

const IsWasm = builtin.target.isWasm();

/// Responsible for transforming platform specific events and emitting them in a compatible format.
/// Users can then register handlers for these events.
pub const EventDispatcher = struct {
    const Self = @This();

    quit_cbs: std.ArrayList(HandlerEntry(OnQuitHandler)),
    keydown_cbs: std.ArrayList(HandlerEntry(OnKeyDownHandler)),
    keyup_cbs: std.ArrayList(HandlerEntry(OnKeyUpHandler)),
    mousedown_cbs: std.ArrayList(HandlerEntry(OnMouseDownHandler)),
    mouseup_cbs: std.ArrayList(HandlerEntry(OnMouseUpHandler)),
    mousemove_cbs: std.ArrayList(HandlerEntry(OnMouseMoveHandler)),
    mousescroll_cbs: std.ArrayList(HandlerEntry(OnMouseScrollHandler)),
    winresize_cbs: std.ArrayList(HandlerEntry(OnWindowResizeHandler)),

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .quit_cbs = std.ArrayList(HandlerEntry(OnQuitHandler)).init(alloc),
            .keydown_cbs = std.ArrayList(HandlerEntry(OnKeyDownHandler)).init(alloc),
            .keyup_cbs = std.ArrayList(HandlerEntry(OnKeyUpHandler)).init(alloc),
            .mousedown_cbs = std.ArrayList(HandlerEntry(OnMouseDownHandler)).init(alloc),
            .mouseup_cbs = std.ArrayList(HandlerEntry(OnMouseUpHandler)).init(alloc),
            .mousemove_cbs = std.ArrayList(HandlerEntry(OnMouseMoveHandler)).init(alloc),
            .mousescroll_cbs = std.ArrayList(HandlerEntry(OnMouseScrollHandler)).init(alloc),
            .winresize_cbs = std.ArrayList(HandlerEntry(OnWindowResizeHandler)).init(alloc),
        };
    }

    pub fn deinit(self: Self) void {
        self.quit_cbs.deinit();
        self.keydown_cbs.deinit();
        self.keyup_cbs.deinit();
        self.mousedown_cbs.deinit();
        self.mouseup_cbs.deinit();
        self.mousemove_cbs.deinit();
        self.mousescroll_cbs.deinit();
        self.winresize_cbs.deinit();
    }

    /// It is recommended to process events before a Window.beginFrame since an event can trigger
    /// a user callback that alters the graphics buffer. eg. Resizing the window.
    pub fn processEvents(self: Self) void {
        if (IsWasm) {
            processWasmEvents(self);
        } else {
            processSdlEvents(self);
        }
    }

    pub fn addOnQuit(self: *Self, ctx: ?*anyopaque, handler: OnQuitHandler) void {
        self.quit_cbs.append(.{ .ctx = ctx, .cb = handler }) catch unreachable;
    }

    pub fn removeOnQuit(self: *Self, handler: OnQuitHandler) void {
        for (self.quit_cbs.items) |it, idx| {
            if (it.cb == handler) {
                self.quit_cbs.orderedRemove(idx);
            }
        }
    }

    pub fn addOnKeyDown(self: *Self, ctx: ?*anyopaque, handler: OnKeyDownHandler) void {
        self.keydown_cbs.append(.{ .ctx = ctx, .cb = handler }) catch unreachable;
    }

    pub fn removeOnKeyDown(self: *Self, handler: OnKeyDownHandler) void {
        for (self.keydown_cbs.items) |it, idx| {
            if (it.cb == handler) {
                self.keydown_cbs.orderedRemove(idx);
            }
        }
    }

    pub fn addOnKeyUp(self: *Self, ctx: ?*anyopaque, handler: OnKeyUpHandler) void {
        self.keyup_cbs.append(.{ .ctx = ctx, .cb = handler }) catch unreachable;
    }

    pub fn removeOnKeyUp(self: *Self, handler: OnKeyUpHandler) void {
        for (self.keyup_cbs.items) |it, idx| {
            if (it.cb == handler) {
                self.keyup_cbs.orderedRemove(idx);
            }
        }
    }

    pub fn addOnMouseDown(self: *Self, ctx: ?*anyopaque, handler: OnMouseDownHandler) void {
        self.mousedown_cbs.append(.{ .ctx = ctx, .cb = handler }) catch unreachable;
    }

    pub fn removeOnMouseDown(self: *Self, handler: OnMouseDownHandler) void {
        for (self.mousedown_cbs.items) |it, idx| {
            if (it.cb == handler) {
                self.mousedown_cbs.orderedRemove(idx);
            }
        }
    }

    pub fn addOnMouseUp(self: *Self, ctx: ?*anyopaque, handler: OnMouseUpHandler) void {
        self.mouseup_cbs.append(.{ .ctx = ctx, .cb = handler }) catch unreachable;
    }

    pub fn removeOnMouseUp(self: *Self, handler: OnMouseUpHandler) void {
        for (self.mouseup_cbs.items) |it, idx| {
            if (it.cb == handler) {
                self.mouseup_cbs.orderedRemove(idx);
            }
        }
    }

    pub fn addOnMouseMove(self: *Self, ctx: ?*anyopaque, handler: OnMouseMoveHandler) void {
        self.mousemove_cbs.append(.{ .ctx = ctx, .cb = handler }) catch unreachable;
    }

    pub fn removeOnMouseMove(self: *Self, handler: OnMouseMoveHandler) void {
        for (self.mousemove_cbs.items) |it, idx| {
            if (it.cb == handler) {
                self.mousemove_cbs.orderedRemove(idx);
            }
        }
    }

    pub fn addOnMouseScroll(self: *Self, ctx: ?*anyopaque, handler: OnMouseScrollHandler) void {
        self.mousescroll_cbs.append(.{ .ctx = ctx, .cb = handler }) catch unreachable;
    }

    pub fn removeOnMouseScroll(self: *Self, handler: OnMouseScrollHandler) void {
        for (self.mousescroll_cbs.items) |it, idx| {
            if (it.cb == handler) {
                self.mousescroll_cbs.orderedRemove(idx);
            }
        }
    }

    pub fn addOnWindowResize(self: *Self, ctx: ?*anyopaque, handler: OnWindowResizeHandler) void {
        self.winresize_cbs.append(.{ .ctx = ctx, .cb = handler }) catch unreachable;
    }

    pub fn removeOnWindowResize(self: *Self, handler: OnWindowResizeHandler) void {
        for (self.winresize_cbs.items) |it, idx| {
            if (it.cb == handler) {
                self.winresize_cbs.orderedRemove(idx);
            }
        }
    }
};

fn processSdlEvents(dispatcher: EventDispatcher) void {
    var event: sdl.SDL_Event = undefined;
    while (sdl.SDL_PollEvent(&event) != 0) {
        switch (event.@"type") {
            sdl.SDL_QUIT => {
                for (dispatcher.quit_cbs.items) |handler| {
                    handler.cb(handler.ctx);
                }
            },
            sdl.SDL_KEYDOWN => {
                const std_event = platform.initSdlKeyDownEvent(event.key);
                for (dispatcher.keydown_cbs.items) |handler| {
                    handler.cb(handler.ctx, std_event);
                }
            },
            sdl.SDL_KEYUP => {
                const std_event = platform.initSdlKeyUpEvent(event.key);
                for (dispatcher.keyup_cbs.items) |handler| {
                    handler.cb(handler.ctx, std_event);
                }
            },
            sdl.SDL_MOUSEBUTTONDOWN => {
                const std_event = platform.initSdlMouseDownEvent(event.button);
                for (dispatcher.mousedown_cbs.items) |handler| {
                    handler.cb(handler.ctx, std_event);
                }
            },
            sdl.SDL_MOUSEBUTTONUP => {
                const std_event = platform.initSdlMouseUpEvent(event.button);
                for (dispatcher.mouseup_cbs.items) |handler| {
                    handler.cb(handler.ctx, std_event);
                }
            },
            sdl.SDL_MOUSEMOTION => {
                if (dispatcher.mousemove_cbs.items.len > 0) {
                    const std_event = platform.initSdlMouseMoveEvent(event.motion);
                    for (dispatcher.mousemove_cbs.items) |handler| {
                        handler.cb(handler.ctx, std_event);
                    }
                }
            },
            sdl.SDL_WINDOWEVENT => {
                switch (event.window.event) {
                    sdl.SDL_WINDOWEVENT_HIDDEN => {
                        // Minimized.
                        // TODO: Don't perform drawing.
                    },
                    sdl.SDL_WINDOWEVENT_SHOWN => {
                        // Restored.
                        // TODO: Reenable drawing.
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

/// Assumes the global wasm input buffer contains a valid slice of the commands to be processed.
fn processWasmEvents(dispatcher: EventDispatcher) void {
    const Command = struct {
        const KeyDown = 1;
        const KeyUp = 2;
        const MouseDown = 3;
        const MouseUp = 4;
        const MouseMove = 5;
        const MouseScroll = 6;
        const WindowResize = 7;
    };

    const input_buf = stdx.wasm.js_buffer.input_buf.items;

    // Process each command.
    var i: usize = 0;
    while (i < input_buf.len) {
        const ctype = input_buf[i];
        switch (ctype) {
            Command.KeyDown => {
                const code = input_buf[i+1];
                const mods = input_buf[i+2];
                const repeat = input_buf[i+3] == 1;
                const std_code = platform.webToCanonicalKeyCode(code);
                const std_event = KeyDownEvent.initWithMods(std_code, mods, repeat);
                i += 4;
                for (dispatcher.keydown_cbs.items) |handler| {
                    handler.cb(handler.ctx, std_event);
                }
            },
            Command.KeyUp => {
                const code = input_buf[i+1];
                const mods = input_buf[i+2];
                const std_code = platform.webToCanonicalKeyCode(code);
                const std_event = KeyUpEvent.initWithMods(std_code, mods);
                i += 3;
                for (dispatcher.keyup_cbs.items) |handler| {
                    handler.cb(handler.ctx, std_event);
                }
            },
            Command.MouseDown => {
                const button = input_buf[i+1];
                const x = std.mem.readIntLittle(i16, input_buf[i+2..i+4][0..2]);
                const y = std.mem.readIntLittle(i16, input_buf[i+4..i+6][0..2]);
                const clicks = input_buf[i+6];
                const std_button = std.meta.intToEnum(MouseButton, button) catch stdx.debug.panicFmt("unsupported button: {}", .{button});
                const std_event = MouseDownEvent.init(std_button, x, y, clicks);
                i += 7;
                for (dispatcher.mousedown_cbs.items) |handler| {
                    handler.cb(handler.ctx, std_event);
                }
            },
            Command.MouseUp => {
                const button = input_buf[i+1];
                const x = std.mem.readIntLittle(i16, input_buf[i+2..i+4][0..2]);
                const y = std.mem.readIntLittle(i16, input_buf[i+4..i+6][0..2]);
                const clicks = input_buf[i+6];
                const std_button = std.meta.intToEnum(MouseButton, button) catch stdx.debug.panicFmt("unsupported button: {}", .{button});
                const std_event = MouseUpEvent.init(std_button, x, y, clicks);
                i += 7;
                for (dispatcher.mouseup_cbs.items) |handler| {
                    handler.cb(handler.ctx, std_event);
                }
            },
            Command.MouseMove => {
                if (dispatcher.mousemove_cbs.items.len > 0) {
                    const x = std.mem.readIntLittle(i16, input_buf[i+1..i+3][0..2]);
                    const y = std.mem.readIntLittle(i16, input_buf[i+3..i+5][0..2]);
                    const std_event = MouseMoveEvent.init(x, y);
                    for (dispatcher.mousemove_cbs.items) |handler| {
                        handler.cb(handler.ctx, std_event);
                    }
                }
                i += 5;
            },
            Command.MouseScroll => {
                const x = std.mem.readIntLittle(i16, input_buf[i+1..i+3][0..2]);
                const y = std.mem.readIntLittle(i16, input_buf[i+3..i+5][0..2]);
                const delta_y = @bitCast(f32, std.mem.readIntLittle(u32, input_buf[i+5..i+9][0..4]));
                const std_event = MouseScrollEvent.init(x, y, delta_y);
                for (dispatcher.mousescroll_cbs.items) |handler| {
                    handler.cb(handler.ctx, std_event);
                }
                i += 9;
            },
            Command.WindowResize => {
                const width = std.mem.readIntLittle(u16, input_buf[i+1..i+3][0..2]);
                const height = std.mem.readIntLittle(u16, input_buf[i+3..i+5][0..2]);
                const std_event = WindowResizeEvent.init(width, height);
                i += 5;
                for (dispatcher.winresize_cbs.items) |handler| {
                    handler.cb(handler.ctx, std_event);
                }
            },
            else => {
                stdx.panicFmt("unknown command {}", .{ctype});
            },
        }
    }
}

fn HandlerEntry(comptime Handler: type) type {
    return struct {
        ctx: ?*anyopaque,
        cb: Handler,
    };
}

const OnQuitHandler = fn (?*anyopaque) void;
const OnKeyDownHandler = fn(?*anyopaque, KeyDownEvent) void;
const OnKeyUpHandler = fn(?*anyopaque, KeyUpEvent) void;
const OnMouseDownHandler = fn(?*anyopaque, MouseDownEvent) void;
const OnMouseUpHandler = fn(?*anyopaque, MouseUpEvent) void;
const OnMouseMoveHandler = fn(?*anyopaque, MouseMoveEvent) void;
const OnMouseScrollHandler = fn(?*anyopaque, MouseScrollEvent) void;
const OnWindowResizeHandler = fn(?*anyopaque, WindowResizeEvent) void;