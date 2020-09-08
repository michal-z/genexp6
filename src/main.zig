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
    while (state.y < window_height and row < 4) : (row += 1) {
        var x: u32 = 0;
        while (x < window_width) : (x += 1) {
            const i = x + state.y * window_width;
            state.image[i * 3 + 0] = 1.0;
            state.image[i * 3 + 1] = 0.0;
            state.image[i * 3 + 2] = 0.0;
        }
        state.y += 1;
    }
}

const osl = struct {
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
};

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
            if (wparam == osl.VK_ESCAPE) {
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
    _ = osl.SetProcessDPIAware();

    const winclass = os.user32.WNDCLASSEXA{
        .style = 0,
        .lpfnWndProc = processWindowMessage,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = @ptrCast(os.HINSTANCE, os.kernel32.GetModuleHandleA(null)),
        .hIcon = null,
        .hCursor = osl.LoadCursorA(null, @intToPtr(os.LPCSTR, 32512)),
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

    var rect = osl.RECT{ .left = 0, .top = 0, .right = window_width, .bottom = window_height };
    _ = osl.AdjustWindowRect(&rect, style, false);

    const window = os.user32.CreateWindowExA(
        0,
        window_name,
        window_name,
        style + osl.WS_VISIBLE,
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
            update(&state);
            glDrawPixels(window_width, window_height, GL_RGB, GL_FLOAT, image.ptr);
            _ = os.gdi32.SwapBuffers(hdc);
        }
    }
}
