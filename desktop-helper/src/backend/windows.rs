//! Windows: EnumWindows/SetForegroundWindow/ShowWindow for windows, SendInput (Unicode for text), GDI BitBlt
//! capture, monitor enumeration, SC_MONITORPOWER, WASAPI endpoint volume.
//!
//! - The process is per-monitor DPI aware, so coordinates are physical virtual-screen pixels (Windows' own desktop
//!   coordinates); `scale` reports each monitor's DPI / 96.
//! - Input into elevated windows is blocked by UIPI unless the helper runs elevated too (→ `permission`).
//! - `set-output` uses the undocumented but long-stable IPolicyConfig interface (as SoundSwitch and others do).
//! - Window ids are HWND values. Virtual desktops have no public API, so `workspaces` is not offered.
//!
//! Every `unsafe` block is a Win32 call with arguments that live for the duration of the call.

#![allow(unsafe_code)]

use super::{
    Backend, CAP_APPS, CAP_AUDIO, CAP_CLIPBOARD, CAP_DPMS, CAP_INPUT, CAP_LAUNCH, CAP_MONITORS, CAP_SCREENSHOT,
    CAP_STREAM, CAP_TEXT, CAP_WINDOW_ACTIONS, CAP_WINDOWS,
};
use crate::frame::{Frame, PixelFormat};
use crate::keys::Key;
use crate::protocol::{Button, Error, Monitor, Output, Rect, Res, Volume, Window, WindowAction, window_id};
use std::ffi::c_void;
use std::mem::size_of;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use windows::Win32::Devices::FunctionDiscovery::PKEY_Device_FriendlyName;
use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS, DwmGetWindowAttribute};
use windows::Win32::Graphics::Gdi::{
    BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DIB_RGB_COLORS, DeleteDC,
    DeleteObject, EnumDisplayMonitors, GetDC, GetDIBits, GetMonitorInfoW, HDC, HMONITOR, MONITOR_DEFAULTTONEAREST,
    MONITORINFO, MONITORINFOEXW, MonitorFromWindow, ReleaseDC, SRCCOPY, SelectObject,
};
use windows::Win32::Media::Audio::Endpoints::IAudioEndpointVolume;
use windows::Win32::Media::Audio::{
    DEVICE_STATE_ACTIVE, IMMDeviceEnumerator, MMDeviceEnumerator, eCommunications, eConsole, eMultimedia, eRender,
};
use windows::Win32::System::Com::StructuredStorage::{PropVariantClear, PropVariantToStringAlloc};
use windows::Win32::System::Com::{
    CLSCTX_ALL, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoTaskMemFree, STGM_READ,
};
use windows::Win32::System::Threading::{
    OpenProcess, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW,
};
use windows::Win32::UI::HiDpi::{
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, GetDpiForMonitor, MDT_EFFECTIVE_DPI, SetProcessDpiAwarenessContext,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBD_EVENT_FLAGS, KEYBDINPUT, KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP,
    KEYEVENTF_UNICODE, MAPVK_VK_TO_VSC, MOUSE_EVENT_FLAGS, MOUSEEVENTF_HWHEEL, MOUSEEVENTF_LEFTDOWN,
    MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN,
    MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_WHEEL, MOUSEINPUT, MapVirtualKeyW, SendInput, VIRTUAL_KEY,
};
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GW_OWNER, GWL_EXSTYLE, GetForegroundWindow, GetWindow, GetWindowLongPtrW, GetWindowRect,
    GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId, HWND_BROADCAST, IsIconic, IsWindow,
    IsWindowVisible, IsZoomed, MONITORINFOF_PRIMARY, PostMessageW, SC_MONITORPOWER, SW_MAXIMIZE, SW_MINIMIZE,
    SW_RESTORE, SW_SHOWNORMAL, SetCursorPos, SetForegroundWindow, ShowWindow, WM_CLOSE, WM_SYSCOMMAND,
    WS_EX_TOOLWINDOW,
};
use windows::core::{BOOL, GUID, IUnknown, Interface, PCWSTR, PWSTR, w};

fn werr(e: windows::core::Error) -> Error {
    Error::failed(format!("Windows: {}", e.message()))
}

fn wide(s: &std::ffi::OsStr) -> Vec<u16> {
    s.encode_wide().chain(Some(0)).collect()
}

fn hwnd_of(id: u64) -> HWND {
    HWND(id as usize as *mut c_void)
}

fn id_of(h: HWND) -> u64 {
    h.0 as usize as u64
}

pub struct Win;

impl Win {
    pub fn new() -> Self {
        // SAFETY: plain call; fails harmlessly if the awareness was already set (e.g. by a manifest).
        let _ = unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
        Win
    }
}

// =====================================================================
// windows

unsafe extern "system" fn collect_hwnd(hwnd: HWND, lp: LPARAM) -> BOOL {
    // SAFETY: lp is the `&mut Vec<HWND>` that top_windows() passes and keeps alive during EnumWindows.
    let v = unsafe { &mut *(lp.0 as *mut Vec<HWND>) };
    v.push(hwnd);
    BOOL(1)
}

/// Top-level windows in Z order (topmost first).
fn top_windows() -> Vec<HWND> {
    let mut v: Vec<HWND> = Vec::new();
    // SAFETY: the callback only touches `v`, which outlives the call.
    let _ = unsafe { EnumWindows(Some(collect_hwnd), LPARAM(&mut v as *mut Vec<HWND> as isize)) };
    v
}

/// Windows a user would see in Alt+Tab: visible, not cloaked (other virtual desktop / suspended UWP),
/// unowned, not tool windows, with a title.
fn is_app_window(h: HWND) -> bool {
    // SAFETY: all calls take the HWND by value and tolerate stale handles.
    unsafe {
        if !IsWindowVisible(h).as_bool() || GetWindow(h, GW_OWNER).is_ok_and(|o| !o.is_invalid()) {
            return false;
        }
        let ex = GetWindowLongPtrW(h, GWL_EXSTYLE) as u32;
        if ex & WS_EX_TOOLWINDOW.0 != 0 || GetWindowTextLengthW(h) == 0 {
            return false;
        }
        let mut cloaked = 0u32;
        let ok =
            DwmGetWindowAttribute(h, DWMWA_CLOAKED, &mut cloaked as *mut u32 as *mut c_void, size_of::<u32>() as u32);
        !(ok.is_ok() && cloaked != 0)
    }
}

fn title(h: HWND) -> String {
    // SAFETY: the buffer outlives the call and its length is passed with it.
    unsafe {
        let n = GetWindowTextLengthW(h).max(0) as usize;
        let mut buf = vec![0u16; n + 1];
        let got = GetWindowTextW(h, &mut buf).max(0) as usize;
        String::from_utf16_lossy(&buf[..got.min(n)])
    }
}

fn window_rect(h: HWND) -> RECT {
    let mut r = RECT::default();
    // SAFETY: `r` outlives the calls; the size passed matches RECT.
    unsafe {
        let ext = DwmGetWindowAttribute(
            h,
            DWMWA_EXTENDED_FRAME_BOUNDS,
            &mut r as *mut RECT as *mut c_void,
            size_of::<RECT>() as u32,
        );
        if ext.is_err() {
            let _ = GetWindowRect(h, &mut r);
        }
    }
    r
}

fn exe_name(pid: u32) -> String {
    // SAFETY: the handle is closed below; the buffer and its size live through the call.
    unsafe {
        let Ok(p) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else { return String::new() };
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(p, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len);
        let _ = CloseHandle(p);
        if ok.is_err() {
            return String::new();
        }
        let path = String::from_utf16_lossy(&buf[..len as usize]);
        Path::new(&path).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
    }
}

fn info(h: HWND, fg: HWND) -> Window {
    let r = window_rect(h);
    let mut pid = 0u32;
    // SAFETY: `pid` outlives the call.
    unsafe { GetWindowThreadProcessId(h, Some(&mut pid as *mut u32)) };
    // SAFETY: by-value handle calls.
    let (minimized, mon) = unsafe { (IsIconic(h).as_bool(), MonitorFromWindow(h, MONITOR_DEFAULTTONEAREST)) };
    let m = monitor_info(mon);
    let fullscreen = m.as_ref().is_some_and(|(_, mr, _)| {
        !minimized && r.left <= mr.left && r.top <= mr.top && r.right >= mr.right && r.bottom >= mr.bottom
    });
    Window {
        id: window_id(id_of(h)),
        title: title(h),
        app_id: exe_name(pid),
        pid: (pid != 0).then_some(pid),
        workspace: None,
        monitor: m.map(|(name, _, _)| name),
        x: r.left,
        y: r.top,
        w: r.right - r.left,
        h: r.bottom - r.top,
        focused: h == fg,
        minimized,
        fullscreen,
        floating: false,
    }
}

fn known_window(id: u64) -> Res<HWND> {
    let h = hwnd_of(id);
    // SAFETY: IsWindow accepts any value.
    if id == 0 || !unsafe { IsWindow(Some(h)) }.as_bool() || !is_app_window(h) {
        return Err(Error::not_found("no such window"));
    }
    Ok(h)
}

// =====================================================================
// monitors

unsafe extern "system" fn collect_monitor(m: HMONITOR, _: HDC, _: *mut RECT, lp: LPARAM) -> BOOL {
    // SAFETY: lp is the `&mut Vec<HMONITOR>` that monitors() passes and keeps alive.
    let v = unsafe { &mut *(lp.0 as *mut Vec<HMONITOR>) };
    v.push(m);
    BOOL(1)
}

/// Device name without the `\\.\` prefix ("DISPLAY1"), rectangle, primary.
fn monitor_info(m: HMONITOR) -> Option<(String, RECT, bool)> {
    let mut mi = MONITORINFOEXW::default();
    mi.monitorInfo.cbSize = size_of::<MONITORINFOEXW>() as u32;
    // SAFETY: MONITORINFOEXW starts with MONITORINFO and cbSize tells Windows the extended size.
    let ok = unsafe { GetMonitorInfoW(m, &mut mi.monitorInfo as *mut MONITORINFO) };
    if !ok.as_bool() {
        return None;
    }
    let len = mi.szDevice.iter().position(|&c| c == 0).unwrap_or(mi.szDevice.len());
    let name = String::from_utf16_lossy(&mi.szDevice[..len]);
    let name = name.trim_start_matches(r"\\.\").to_string();
    Some((name, mi.monitorInfo.rcMonitor, mi.monitorInfo.dwFlags & MONITORINFOF_PRIMARY != 0))
}

// =====================================================================
// input

fn send(inputs: &[INPUT]) -> Res<()> {
    // SAFETY: the slice and the struct size are passed together.
    let n = unsafe { SendInput(inputs, size_of::<INPUT>() as i32) };
    if n as usize == inputs.len() {
        Ok(())
    } else {
        Err(Error::permission("input was blocked (the target window may run as administrator)"))
    }
}

fn mouse(flags: MOUSE_EVENT_FLAGS, data: i32) -> INPUT {
    INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT { dx: 0, dy: 0, mouseData: data as u32, dwFlags: flags, time: 0, dwExtraInfo: 0 },
        },
    }
}

fn key_input(vk: u16, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT { wVk: VIRTUAL_KEY(vk), wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 },
        },
    }
}

fn vk_event(k: Key, up: bool) -> INPUT {
    let (vk, ext) = k.vk();
    // SAFETY: pure lookup.
    let scan = unsafe { MapVirtualKeyW(vk as u32, MAPVK_VK_TO_VSC) } as u16;
    let mut flags = KEYBD_EVENT_FLAGS(0);
    if ext {
        flags |= KEYEVENTF_EXTENDEDKEY;
    }
    if up {
        flags |= KEYEVENTF_KEYUP;
    }
    key_input(vk, scan, flags)
}

/// Text as KEYEVENTF_UNICODE events (layout-independent); newline and tab as their keys.
fn text_inputs(text: &str) -> Vec<INPUT> {
    let mut v = Vec::with_capacity(text.len() * 2);
    for ch in text.chars() {
        match ch {
            '\r' => {}
            '\n' => v.extend([vk_event(Key::Enter, false), vk_event(Key::Enter, true)]),
            '\t' => v.extend([vk_event(Key::Tab, false), vk_event(Key::Tab, true)]),
            c => {
                let mut units = [0u16; 2];
                for &u in c.encode_utf16(&mut units).iter() {
                    v.push(key_input(0, u, KEYEVENTF_UNICODE));
                    v.push(key_input(0, u, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
                }
            }
        }
    }
    v
}

// =====================================================================
// audio (WASAPI)

const CLSID_POLICY_CONFIG: GUID = GUID::from_u128(0x870af99c_171d_4f9e_af0d_e63df40c2bc9);
const IID_POLICY_CONFIG: GUID = GUID::from_u128(0xf8679f50_850a_41cf_9c72_430f290290c8);

fn com() {
    // SAFETY: plain call; S_FALSE/RPC_E_CHANGED_MODE (already initialized on this thread) are fine.
    let _ = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
}

fn enumerator() -> Res<IMMDeviceEnumerator> {
    com();
    // SAFETY: standard COM activation.
    unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) }.map_err(werr)
}

fn endpoint_volume() -> Res<IAudioEndpointVolume> {
    let en = enumerator()?;
    // SAFETY: COM calls on live interfaces.
    unsafe {
        en.GetDefaultAudioEndpoint(eRender, eConsole)
            .and_then(|d| d.Activate::<IAudioEndpointVolume>(CLSCTX_ALL, None))
            .map_err(werr)
    }
}

/// Takes a COM-allocated string and frees it.
fn take_pwstr(p: PWSTR) -> String {
    // SAFETY: `p` came from a COM allocator and is freed exactly once here.
    unsafe {
        let s = p.to_string().unwrap_or_default();
        CoTaskMemFree(Some(p.0 as *const c_void));
        s
    }
}

fn list_outputs() -> Res<Vec<Output>> {
    let en = enumerator()?;
    // SAFETY: COM calls on live interfaces; strings and PROPVARIANTs are freed after use.
    unsafe {
        let default = en.GetDefaultAudioEndpoint(eRender, eConsole).and_then(|d| d.GetId()).map(take_pwstr).ok();
        let all = en.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE).map_err(werr)?;
        let mut out = Vec::new();
        for i in 0..all.GetCount().map_err(werr)? {
            let Ok(dev) = all.Item(i) else { continue };
            let Ok(id) = dev.GetId().map(take_pwstr) else { continue };
            let name = dev
                .OpenPropertyStore(STGM_READ)
                .and_then(|store| {
                    let mut pv = store.GetValue(&PKEY_Device_FriendlyName)?;
                    let s = PropVariantToStringAlloc(&pv).map(take_pwstr);
                    let _ = PropVariantClear(&mut pv);
                    s
                })
                .unwrap_or_else(|_| id.clone());
            out.push(Output { default: default.as_deref() == Some(id.as_str()), id, name });
        }
        Ok(out)
    }
}

fn set_default_output(id: &str) -> Res<()> {
    com();
    let id_w = wide(std::ffi::OsStr::new(id));
    // SAFETY: IPolicyConfig (Windows 7+) is IUnknown + 10 methods, then SetDefaultEndpoint(PCWSTR, ERole) at
    // vtable slot 13. `raw` is owned by `owned` and released when it drops; `id_w` outlives the calls.
    unsafe {
        let unk: IUnknown = CoCreateInstance(&CLSID_POLICY_CONFIG, None, CLSCTX_ALL).map_err(werr)?;
        let mut raw: *mut c_void = std::ptr::null_mut();
        unk.query(&IID_POLICY_CONFIG, &mut raw).ok().map_err(werr)?;
        if raw.is_null() {
            return Err(Error::unsupported("no IPolicyConfig on this Windows"));
        }
        let owned = IUnknown::from_raw(raw);
        type SetDefault = unsafe extern "system" fn(*mut c_void, PCWSTR, i32) -> windows::core::HRESULT;
        let vtbl = *(raw as *const *const SetDefault);
        let set: SetDefault = *vtbl.add(13);
        for role in [eConsole, eMultimedia, eCommunications] {
            set(raw, PCWSTR(id_w.as_ptr()), role.0).ok().map_err(werr)?;
        }
        drop(owned);
    }
    Ok(())
}

/// Opens a file the way Explorer would (used for Start menu shortcuts).
pub fn shell_open(path: &Path) -> Res<()> {
    let p = wide(path.as_os_str());
    // SAFETY: both strings are NUL-terminated and outlive the call.
    let r =
        unsafe { ShellExecuteW(None, w!("open"), PCWSTR(p.as_ptr()), PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL) };
    // ShellExecute returns a value > 32 on success.
    if r.0 as isize > 32 { Ok(()) } else { Err(Error::failed(format!("could not start (code {})", r.0 as isize))) }
}

impl Backend for Win {
    fn name(&self) -> &'static str {
        "windows"
    }

    fn capabilities(&self) -> Vec<&'static str> {
        vec![
            CAP_WINDOWS,
            CAP_WINDOW_ACTIONS,
            CAP_MONITORS,
            CAP_SCREENSHOT,
            CAP_STREAM,
            CAP_INPUT,
            CAP_TEXT,
            CAP_APPS,
            CAP_LAUNCH,
            CAP_DPMS,
            CAP_CLIPBOARD,
            CAP_AUDIO,
        ]
    }

    fn windows(&self) -> Res<Vec<Window>> {
        // SAFETY: plain call.
        let fg = unsafe { GetForegroundWindow() };
        let mut v: Vec<Window> = top_windows().into_iter().filter(|&h| is_app_window(h)).map(|h| info(h, fg)).collect();
        v.sort_by_key(|w| !w.focused);
        Ok(v)
    }

    fn focused(&self) -> Res<Option<Window>> {
        // SAFETY: plain call.
        let fg = unsafe { GetForegroundWindow() };
        Ok((!fg.is_invalid() && is_app_window(fg)).then(|| info(fg, fg)))
    }

    fn window_action(&self, id: u64, action: WindowAction) -> Res<()> {
        let h = known_window(id)?;
        // SAFETY: by-value handle calls on a window that existed a moment ago (stale handles just fail).
        unsafe {
            match action {
                WindowAction::Focus => {
                    if IsIconic(h).as_bool() {
                        let _ = ShowWindow(h, SW_RESTORE);
                    }
                    // Windows lets only the process with the last input move the foreground; a synthetic Alt tap
                    // makes that us.
                    send(&[vk_event(Key::Alt, false), vk_event(Key::Alt, true)])?;
                    if !SetForegroundWindow(h).as_bool() {
                        return Err(Error::failed("Windows refused to bring the window to the front"));
                    }
                }
                WindowAction::Close => PostMessageW(Some(h), WM_CLOSE, WPARAM(0), LPARAM(0)).map_err(werr)?,
                WindowAction::Minimize => {
                    let _ = ShowWindow(h, SW_MINIMIZE);
                }
                WindowAction::Maximize => {
                    let _ = ShowWindow(h, if IsZoomed(h).as_bool() { SW_RESTORE } else { SW_MAXIMIZE });
                }
                WindowAction::Fullscreen | WindowAction::Float => {
                    return Err(Error::unsupported("Windows has no general way to do this"));
                }
            }
        }
        Ok(())
    }

    fn monitors(&self) -> Res<Vec<Monitor>> {
        let mut hs: Vec<HMONITOR> = Vec::new();
        // SAFETY: the callback only touches `hs`, which outlives the call.
        let _ = unsafe {
            EnumDisplayMonitors(None, None, Some(collect_monitor), LPARAM(&mut hs as *mut Vec<HMONITOR> as isize))
        };
        Ok(hs
            .into_iter()
            .filter_map(|m| {
                let (name, r, primary) = monitor_info(m)?;
                let (mut dx, mut dy) = (96u32, 96u32);
                // SAFETY: out-pointers to locals.
                let _ = unsafe { GetDpiForMonitor(m, MDT_EFFECTIVE_DPI, &mut dx, &mut dy) };
                Some(Monitor {
                    id: name.clone(),
                    name,
                    x: r.left,
                    y: r.top,
                    w: r.right - r.left,
                    h: r.bottom - r.top,
                    scale: dx as f64 / 96.0,
                    primary,
                })
            })
            .collect())
    }

    fn capture(&self, r: Rect) -> Res<Frame> {
        let (w, h) = (r.w, r.h);
        let mut data = vec![0u8; w as usize * h as usize * 4];
        // SAFETY: every GDI object created here is selected out and deleted before returning; the pixel buffer
        // holds exactly h rows of w 32-bit pixels, as described by `bi`.
        let lines = unsafe {
            let screen = GetDC(None);
            if screen.is_invalid() {
                return Err(Error::failed("no screen device context"));
            }
            let mem = CreateCompatibleDC(Some(screen));
            let bmp = CreateCompatibleBitmap(screen, w, h);
            let old = SelectObject(mem, bmp.into());
            let blt = BitBlt(mem, 0, 0, w, h, Some(screen), r.x, r.y, SRCCOPY);
            let mut bi = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: w,
                    biHeight: -h, // top-down rows
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                },
                ..Default::default()
            };
            let lines = if blt.is_ok() {
                GetDIBits(mem, bmp, 0, h as u32, Some(data.as_mut_ptr() as *mut c_void), &mut bi, DIB_RGB_COLORS)
            } else {
                0
            };
            SelectObject(mem, old);
            let _ = DeleteObject(bmp.into());
            let _ = DeleteDC(mem);
            ReleaseDC(None, screen);
            lines
        };
        if lines != h {
            // BitBlt fails on the secure desktop (UAC prompt, lock screen).
            return Err(Error::failed("screen capture failed (secure desktop?)"));
        }
        Frame::new(w as u32, h as u32, w as usize * 4, PixelFormat::Bgrx, data)
    }

    fn pointer(&self, x: f64, y: f64) -> Res<()> {
        // SAFETY: plain call.
        unsafe { SetCursorPos(x.round() as i32, y.round() as i32) }.map_err(werr)?;
        // A zero relative move so apps that only watch raw input see motion too.
        send(&[mouse(MOUSEEVENTF_MOVE, 0)])
    }

    fn button(&self, button: Button, down: bool) -> Res<()> {
        let f = match (button, down) {
            (Button::Left, true) => MOUSEEVENTF_LEFTDOWN,
            (Button::Left, false) => MOUSEEVENTF_LEFTUP,
            (Button::Right, true) => MOUSEEVENTF_RIGHTDOWN,
            (Button::Right, false) => MOUSEEVENTF_RIGHTUP,
            (Button::Middle, true) => MOUSEEVENTF_MIDDLEDOWN,
            (Button::Middle, false) => MOUSEEVENTF_MIDDLEUP,
        };
        send(&[mouse(f, 0)])
    }

    fn scroll(&self, dx: i32, dy: i32) -> Res<()> {
        // WHEEL_DELTA = 120 per notch; positive wheel scrolls up, positive hwheel right.
        let mut v = Vec::new();
        if dy != 0 {
            v.push(mouse(MOUSEEVENTF_WHEEL, -dy * 120));
        }
        if dx != 0 {
            v.push(mouse(MOUSEEVENTF_HWHEEL, dx * 120));
        }
        send(&v)
    }

    fn key(&self, keys: &[Key]) -> Res<()> {
        let mut v: Vec<INPUT> = keys.iter().map(|&k| vk_event(k, false)).collect();
        v.extend(keys.iter().rev().map(|&k| vk_event(k, true)));
        send(&v)
    }

    fn text(&self, text: &str) -> Res<()> {
        for chunk in text_inputs(text).chunks(256) {
            send(chunk)?;
        }
        Ok(())
    }

    fn dpms(&self, on: bool) -> Res<()> {
        if on {
            // SC_MONITORPOWER -1 is ignored by modern Windows; a tiny mouse move wakes the screens.
            let mut a = mouse(MOUSEEVENTF_MOVE, 0);
            a.Anonymous.mi.dx = 1;
            let mut b = mouse(MOUSEEVENTF_MOVE, 0);
            b.Anonymous.mi.dx = -1;
            return send(&[a, b]);
        }
        // SAFETY: posting a system command; nothing is borrowed.
        unsafe { PostMessageW(Some(HWND_BROADCAST), WM_SYSCOMMAND, WPARAM(SC_MONITORPOWER as usize), LPARAM(2)) }
            .map_err(werr)
    }

    fn clipboard_get(&self) -> Res<Option<String>> {
        let mut c = arboard::Clipboard::new().map_err(|e| Error::failed(format!("clipboard: {e}")))?;
        match c.get_text() {
            Ok(t) => Ok(Some(t)),
            Err(arboard::Error::ContentNotAvailable) => Ok(None),
            Err(e) => Err(Error::failed(format!("clipboard: {e}"))),
        }
    }

    fn clipboard_set(&self, text: &str) -> Res<()> {
        let mut c = arboard::Clipboard::new().map_err(|e| Error::failed(format!("clipboard: {e}")))?;
        c.set_text(text).map_err(|e| Error::failed(format!("clipboard: {e}")))
    }

    fn volume(&self) -> Res<Volume> {
        let v = endpoint_volume()?;
        // SAFETY: COM calls on a live interface.
        unsafe {
            let level = v.GetMasterVolumeLevelScalar().map_err(werr)?;
            let muted = v.GetMute().map_err(werr)?.as_bool();
            Ok(Volume { percent: (level * 100.0).round() as u32, muted })
        }
    }

    fn set_volume(&self, percent: Option<u32>, muted: Option<bool>) -> Res<Volume> {
        let v = endpoint_volume()?;
        // SAFETY: COM calls on a live interface; a null event context is allowed.
        unsafe {
            if let Some(p) = percent {
                // Windows has no boost above 100 %.
                v.SetMasterVolumeLevelScalar(p.min(100) as f32 / 100.0, std::ptr::null()).map_err(werr)?;
            }
            if let Some(m) = muted {
                v.SetMute(m, std::ptr::null()).map_err(werr)?;
            }
        }
        self.volume()
    }

    fn outputs(&self) -> Res<Vec<Output>> {
        list_outputs()
    }

    fn set_output(&self, id: &str) -> Res<Vec<Output>> {
        if !list_outputs()?.iter().any(|o| o.id == id) {
            return Err(Error::not_found("no such output"));
        }
        set_default_output(id)?;
        list_outputs()
    }
}
