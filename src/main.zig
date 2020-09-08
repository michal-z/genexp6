const std = @import("std");
const assert = std.debug.assert;
const os = std.os.windows;

const window_name = "generative art experiment 6";
const window_width = 2 * 1024;
const window_height = 2 * 1024;

const State = struct {
    image: []f32,
    y: u32 = 0,
};

fn update(state: *State) void {
    var row: u32 = 0;
    while (state.y < window_height and row < 4) {
        var x: u32 = 0;
        const y = state.y + row;
        while (x < window_width) : (x += 1) {
            const i = x + y * window_width;
            state.image[i * 3 + 0] = 1.0;
            state.image[i * 3 + 1] = 0.0;
            state.image[i * 3 + 2] = 0.0;
        }
        state.y += 1;
        row += 1;
    }
}

fn updateFrameStats(window: ?os.HWND, name: [*:0]const u8) struct { time: f64, delta_time: f32 } {
    const state = struct {
        var timer: std.time.Timer = undefined;
        var previous_time_ns: u64 = 0;
        var header_refresh_time_ns: u64 = 0;
        var frame_count: u64 = ~@as(u64, 0);
    };

    if (state.frame_count == ~@as(u64, 0)) {
        state.timer = std.time.Timer.start() catch unreachable;
        state.previous_time_ns = 0;
        state.header_refresh_time_ns = 0;
        state.frame_count = 0;
    }

    const now_ns = state.timer.read();
    const time = @intToFloat(f64, now_ns) / std.time.ns_per_s;
    const delta_time = @intToFloat(f32, now_ns - state.previous_time_ns) / std.time.ns_per_s;
    state.previous_time_ns = now_ns;

    if ((now_ns - state.header_refresh_time_ns) >= std.time.ns_per_s) {
        const t = @intToFloat(f64, now_ns - state.header_refresh_time_ns) / std.time.ns_per_s;
        const fps = @intToFloat(f64, state.frame_count) / t;
        const ms = (1.0 / fps) * 1000.0;

        var buffer = [_]u8{0} ** 128;
        const buffer_slice = buffer[0 .. buffer.len - 1];
        const header = std.fmt.bufPrint(
            buffer_slice,
            "[{d:.1} fps  {d:.3} ms] {}",
            .{ fps, ms, name },
        ) catch buffer_slice;

        _ = SetWindowTextA(window, @ptrCast(os.LPCSTR, header.ptr));

        state.header_refresh_time_ns = now_ns;
        state.frame_count = 0;
    }
    state.frame_count += 1;

    return .{ .time = time, .delta_time = delta_time };
}

const WS_VISIBLE = 0x10000000;
const VK_ESCAPE = 0x001B;

const RECT = extern struct {
    left: os.LONG,
    top: os.LONG,
    right: os.LONG,
    bottom: os.LONG,
};

extern "kernel32" fn AdjustWindowRect(
    lpRect: ?*RECT,
    dwStyle: os.DWORD,
    bMenu: bool,
) callconv(.Stdcall) bool;

extern "user32" fn SetProcessDPIAware() callconv(.Stdcall) bool;

extern "user32" fn SetWindowTextA(
    hWnd: ?os.HWND,
    lpString: os.LPCSTR,
) callconv(.Stdcall) bool;

extern "user32" fn LoadCursorA(
    hInstance: ?os.HINSTANCE,
    lpCursorName: os.LPCSTR,
) callconv(.Stdcall) ?os.HCURSOR;

fn processWindowMessage(
    window: os.HWND,
    message: os.UINT,
    wparam: os.WPARAM,
    lparam: os.LPARAM,
) callconv(.Stdcall) os.LRESULT {
    const processed = switch (message) {
        os.user32.WM_DESTROY => blk: {
            os.user32.PostQuitMessage(0);
            break :blk true;
        },
        os.user32.WM_KEYDOWN => blk: {
            if (wparam == VK_ESCAPE) {
                os.user32.PostQuitMessage(0);
                break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
    return if (processed) null else os.user32.DefWindowProcA(window, message, wparam, lparam);
}

pub fn main() !void {
    _ = SetProcessDPIAware();

    const winclass = os.user32.WNDCLASSEXA{
        .style = 0,
        .lpfnWndProc = processWindowMessage,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = @ptrCast(os.HINSTANCE, os.kernel32.GetModuleHandleA(null)),
        .hIcon = null,
        .hCursor = LoadCursorA(null, @intToPtr(os.LPCSTR, 32512)),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = window_name,
        .hIconSm = null,
    };
    _ = os.user32.RegisterClassExA(&winclass);

    const style = os.user32.WS_OVERLAPPED +
        os.user32.WS_SYSMENU +
        os.user32.WS_CAPTION +
        os.user32.WS_MINIMIZEBOX;

    var rect = RECT{ .left = 0, .top = 0, .right = window_width, .bottom = window_height };
    _ = AdjustWindowRect(&rect, style, false);

    const window = os.user32.CreateWindowExA(
        0,
        window_name,
        window_name,
        style + WS_VISIBLE,
        -1,
        -1,
        rect.right - rect.left,
        rect.bottom - rect.top,
        null,
        null,
        winclass.hInstance,
        null,
    );

    const hdc = os.user32.GetDC(window);
    {
        var pfd = std.mem.zeroes(os.gdi32.PIXELFORMATDESCRIPTOR);
        pfd.nSize = @sizeOf(os.gdi32.PIXELFORMATDESCRIPTOR);
        pfd.nVersion = 1;
        pfd.dwFlags = os.user32.PFD_SUPPORT_OPENGL +
            os.user32.PFD_DOUBLEBUFFER +
            os.user32.PFD_DRAW_TO_WINDOW;
        pfd.iPixelType = os.user32.PFD_TYPE_RGBA;
        pfd.cColorBits = 24;
        const pixel_format = os.gdi32.ChoosePixelFormat(hdc, &pfd);
        if (!os.gdi32.SetPixelFormat(hdc, pixel_format, &pfd)) {
            std.log.err("Failed to set pixel format.", .{});
            return;
        }
    }

    var opengl32_dll = std.DynLib.open("/windows/system32/opengl32.dll") catch unreachable;
    const wglCreateContext = opengl32_dll.lookup(
        fn (?os.HDC) callconv(.Stdcall) ?os.HGLRC,
        "wglCreateContext",
    ).?;
    const wglDeleteContext = opengl32_dll.lookup(
        fn (?os.HGLRC) callconv(.Stdcall) bool,
        "wglDeleteContext",
    ).?;
    const wglMakeCurrent = opengl32_dll.lookup(
        fn (?os.HDC, ?os.HGLRC) callconv(.Stdcall) bool,
        "wglMakeCurrent",
    ).?;
    const wglGetProcAddress = opengl32_dll.lookup(
        fn (os.LPCSTR) callconv(.Stdcall) ?os.FARPROC,
        "wglGetProcAddress",
    ).?;

    const opengl_context = wglCreateContext(hdc);
    if (!wglMakeCurrent(hdc, opengl_context)) {
        std.log.err("Failed to create OpenGL context.", .{});
        return;
    }
    defer {
        _ = wglMakeCurrent(null, null);
        _ = wglDeleteContext(opengl_context);
    }

    const wglSwapIntervalEXT = @ptrCast(
        fn (c_int) callconv(.Stdcall) bool,
        wglGetProcAddress("wglSwapIntervalEXT").?,
    );
    _ = wglSwapIntervalEXT(1);

    const glDrawPixels = opengl32_dll.lookup(
        fn (c_int, c_int, c_uint, c_uint, *const c_void) callconv(.Stdcall) void,
        "glDrawPixels",
    ).?;
    const GL_FLOAT = 0x1406;
    const GL_RGB = 0x1907;

    const image = try std.heap.page_allocator.alloc(f32, window_width * window_height * 3);
    defer std.heap.page_allocator.free(image);
    std.mem.set(f32, image, 0.0);

    var state = State{
        .image = image,
    };

    while (true) {
        var message = std.mem.zeroes(os.user32.MSG);
        if (os.user32.PeekMessageA(&message, null, 0, 0, os.user32.PM_REMOVE)) {
            _ = os.user32.DispatchMessageA(&message);
            if (message.message == os.user32.WM_QUIT)
                break;
        } else {
            const stats = updateFrameStats(window, window_name);
            update(&state);
            glDrawPixels(window_width, window_height, GL_RGB, GL_FLOAT, image.ptr);
            _ = os.gdi32.SwapBuffers(hdc);
        }
    }
}
