//! Key names of the protocol and their codes per platform. Pure tables, so every platform's mapping is tested
//! on any host.

#![allow(dead_code)] // each platform uses its own table

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    Ctrl,
    Shift,
    Alt,
    Super,
    Enter,
    Escape,
    Tab,
    Backspace,
    Delete,
    Insert,
    Home,
    End,
    PageUp,
    PageDown,
    Up,
    Down,
    Left,
    Right,
    Space,
    /// F1…F12.
    F(u8),
    PrintScreen,
    VolumeUp,
    VolumeDown,
    Mute,
    PlayPause,
    Next,
    Previous,
    /// `a`…`z` or `0`…`9`.
    Char(char),
}

impl Key {
    pub fn parse(name: &str) -> Option<Key> {
        Some(match name {
            "ctrl" => Key::Ctrl,
            "shift" => Key::Shift,
            "alt" => Key::Alt,
            "super" => Key::Super,
            "enter" => Key::Enter,
            "escape" => Key::Escape,
            "tab" => Key::Tab,
            "backspace" => Key::Backspace,
            "delete" => Key::Delete,
            "insert" => Key::Insert,
            "home" => Key::Home,
            "end" => Key::End,
            "pageup" => Key::PageUp,
            "pagedown" => Key::PageDown,
            "up" => Key::Up,
            "down" => Key::Down,
            "left" => Key::Left,
            "right" => Key::Right,
            "space" => Key::Space,
            "printscreen" => Key::PrintScreen,
            "volumeup" => Key::VolumeUp,
            "volumedown" => Key::VolumeDown,
            "mute" => Key::Mute,
            "playpause" => Key::PlayPause,
            "next" => Key::Next,
            "previous" => Key::Previous,
            _ => {
                if let Some(n) = name.strip_prefix('f').and_then(|n| n.parse::<u8>().ok())
                    && (1..=12).contains(&n)
                    && !name.starts_with("f0")
                {
                    return Some(Key::F(n));
                }
                let mut it = name.chars();
                match (it.next(), it.next()) {
                    (Some(c), None) if c.is_ascii_lowercase() || c.is_ascii_digit() => Key::Char(c),
                    _ => return None,
                }
            }
        })
    }

    pub fn is_modifier(self) -> bool {
        matches!(self, Key::Ctrl | Key::Shift | Key::Alt | Key::Super)
    }

    /// X11 keysym (also used by the RemoteDesktop portal).
    pub fn keysym(self) -> u32 {
        match self {
            Key::Ctrl => 0xffe3,
            Key::Shift => 0xffe1,
            Key::Alt => 0xffe9,
            Key::Super => 0xffeb,
            Key::Enter => 0xff0d,
            Key::Escape => 0xff1b,
            Key::Tab => 0xff09,
            Key::Backspace => 0xff08,
            Key::Delete => 0xffff,
            Key::Insert => 0xff63,
            Key::Home => 0xff50,
            Key::End => 0xff57,
            Key::PageUp => 0xff55,
            Key::PageDown => 0xff56,
            Key::Up => 0xff52,
            Key::Down => 0xff54,
            Key::Left => 0xff51,
            Key::Right => 0xff53,
            Key::Space => 0x20,
            Key::F(n) => 0xffbe + (n as u32 - 1),
            Key::PrintScreen => 0xff61,
            Key::VolumeUp => 0x1008ff13,
            Key::VolumeDown => 0x1008ff11,
            Key::Mute => 0x1008ff12,
            Key::PlayPause => 0x1008ff14,
            Key::Next => 0x1008ff17,
            Key::Previous => 0x1008ff16,
            Key::Char(c) => c as u32,
        }
    }

    /// xkb keysym name (`wtype -k`).
    pub fn xkb_name(self) -> String {
        match self {
            Key::Ctrl => "Control_L",
            Key::Shift => "Shift_L",
            Key::Alt => "Alt_L",
            Key::Super => "Super_L",
            Key::Enter => "Return",
            Key::Escape => "Escape",
            Key::Tab => "Tab",
            Key::Backspace => "BackSpace",
            Key::Delete => "Delete",
            Key::Insert => "Insert",
            Key::Home => "Home",
            Key::End => "End",
            Key::PageUp => "Prior",
            Key::PageDown => "Next",
            Key::Up => "Up",
            Key::Down => "Down",
            Key::Left => "Left",
            Key::Right => "Right",
            Key::Space => "space",
            Key::F(n) => return format!("F{n}"),
            Key::PrintScreen => "Print",
            Key::VolumeUp => "XF86AudioRaiseVolume",
            Key::VolumeDown => "XF86AudioLowerVolume",
            Key::Mute => "XF86AudioMute",
            Key::PlayPause => "XF86AudioPlay",
            Key::Next => "XF86AudioNext",
            Key::Previous => "XF86AudioPrev",
            Key::Char(c) => return c.to_string(),
        }
        .to_string()
    }

    /// `wtype -M/-m` modifier name.
    pub fn wtype_modifier(self) -> Option<&'static str> {
        match self {
            Key::Ctrl => Some("ctrl"),
            Key::Shift => Some("shift"),
            Key::Alt => Some("alt"),
            Key::Super => Some("logo"),
            _ => None,
        }
    }

    /// Windows virtual-key code and whether it needs KEYEVENTF_EXTENDEDKEY.
    pub fn vk(self) -> (u16, bool) {
        match self {
            Key::Ctrl => (0xa2, false),  // VK_LCONTROL
            Key::Shift => (0xa0, false), // VK_LSHIFT
            Key::Alt => (0xa4, false),   // VK_LMENU
            Key::Super => (0x5b, true),  // VK_LWIN
            Key::Enter => (0x0d, false),
            Key::Escape => (0x1b, false),
            Key::Tab => (0x09, false),
            Key::Backspace => (0x08, false),
            Key::Delete => (0x2e, true),
            Key::Insert => (0x2d, true),
            Key::Home => (0x24, true),
            Key::End => (0x23, true),
            Key::PageUp => (0x21, true),
            Key::PageDown => (0x22, true),
            Key::Up => (0x26, true),
            Key::Down => (0x28, true),
            Key::Left => (0x25, true),
            Key::Right => (0x27, true),
            Key::Space => (0x20, false),
            Key::F(n) => (0x70 + (n as u16 - 1), false),
            Key::PrintScreen => (0x2c, true),
            Key::VolumeUp => (0xaf, true),
            Key::VolumeDown => (0xae, true),
            Key::Mute => (0xad, true),
            Key::PlayPause => (0xb3, true),
            Key::Next => (0xb0, true),
            Key::Previous => (0xb1, true),
            Key::Char(c) => (c.to_ascii_uppercase() as u16, false),
        }
    }

    /// macOS virtual keycode (kVK_*, ANSI positions). `None`: no such key (media keys are system events there).
    pub fn mac_keycode(self) -> Option<u16> {
        Some(match self {
            Key::Ctrl => 0x3b,
            Key::Shift => 0x38,
            Key::Alt => 0x3a,
            Key::Super => 0x37, // Command
            Key::Enter => 0x24,
            Key::Escape => 0x35,
            Key::Tab => 0x30,
            Key::Backspace => 0x33,
            Key::Delete => 0x75, // forward delete
            Key::Insert => return None,
            Key::Home => 0x73,
            Key::End => 0x77,
            Key::PageUp => 0x74,
            Key::PageDown => 0x79,
            Key::Up => 0x7e,
            Key::Down => 0x7d,
            Key::Left => 0x7b,
            Key::Right => 0x7c,
            Key::Space => 0x31,
            Key::F(n) => [0x7a, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6d, 0x67, 0x6f][n as usize - 1],
            Key::PrintScreen => return None,
            Key::VolumeUp => 0x48,
            Key::VolumeDown => 0x49,
            Key::Mute => 0x4a,
            Key::PlayPause | Key::Next | Key::Previous => return None,
            Key::Char(c) => mac_char(c)?,
        })
    }
}

fn mac_char(c: char) -> Option<u16> {
    const LETTERS: [u16; 26] = [
        0x00, 0x0b, 0x08, 0x02, 0x0e, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2e, // a…m
        0x2d, 0x1f, 0x23, 0x0c, 0x0f, 0x01, 0x11, 0x20, 0x09, 0x0d, 0x07, 0x10, 0x06, // n…z
    ];
    const DIGITS: [u16; 10] = [0x1d, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1a, 0x1c, 0x19];
    match c {
        'a'..='z' => Some(LETTERS[c as usize - 'a' as usize]),
        '0'..='9' => Some(DIGITS[c as usize - '0' as usize]),
        _ => None,
    }
}

/// X11 keysym for a character typed as text.
pub fn char_keysym(c: char) -> u32 {
    match c {
        '\n' | '\r' => 0xff0d,
        '\t' => 0xff09,
        '\u{8}' => 0xff08,
        // Latin-1 keysyms equal their code points; everything else uses the Unicode keysym range.
        ' '..='~' | '\u{a0}'..='\u{ff}' => c as u32,
        _ => 0x0100_0000 + c as u32,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [&str; 26] = [
        "ctrl",
        "shift",
        "alt",
        "super",
        "enter",
        "escape",
        "tab",
        "backspace",
        "delete",
        "insert",
        "home",
        "end",
        "pageup",
        "pagedown",
        "up",
        "down",
        "left",
        "right",
        "space",
        "printscreen",
        "volumeup",
        "volumedown",
        "mute",
        "playpause",
        "next",
        "previous",
    ];

    #[test]
    fn names() {
        for n in ALL {
            assert!(Key::parse(n).is_some(), "{n}");
        }
        assert_eq!(Key::parse("f1"), Some(Key::F(1)));
        assert_eq!(Key::parse("f12"), Some(Key::F(12)));
        for bad in ["f0", "f13", "f01", "F1", "", "aa", "A", "ü", "-", "ctrl "] {
            assert_eq!(Key::parse(bad), None, "{bad}");
        }
        assert_eq!(Key::parse("q"), Some(Key::Char('q')));
        assert_eq!(Key::parse("7"), Some(Key::Char('7')));
        assert!(Key::Super.is_modifier() && !Key::Enter.is_modifier());
    }

    fn every_key() -> Vec<Key> {
        let mut v: Vec<Key> = ALL.iter().map(|n| Key::parse(n).unwrap()).collect();
        v.extend((1..=12).map(Key::F));
        v.extend(('a'..='z').chain('0'..='9').map(Key::Char));
        v
    }

    #[test]
    fn x11_keysyms() {
        assert_eq!(Key::Enter.keysym(), 0xff0d);
        assert_eq!(Key::F(1).keysym(), 0xffbe);
        assert_eq!(Key::F(12).keysym(), 0xffc9);
        assert_eq!(Key::Char('t').keysym(), 0x74);
        assert_eq!(Key::PlayPause.keysym(), 0x1008ff14);
        let mut syms: Vec<u32> = every_key().iter().map(|k| k.keysym()).collect();
        let n = syms.len();
        syms.sort();
        syms.dedup();
        assert_eq!(syms.len(), n, "keysyms are unique");
    }

    #[test]
    fn wtype_names() {
        assert_eq!(Key::PageUp.xkb_name(), "Prior");
        assert_eq!(Key::F(5).xkb_name(), "F5");
        assert_eq!(Key::Char('x').xkb_name(), "x");
        assert_eq!(Key::Super.wtype_modifier(), Some("logo"));
        assert_eq!(Key::Enter.wtype_modifier(), None);
    }

    #[test]
    fn windows_vks() {
        assert_eq!(Key::Char('a').vk(), (0x41, false));
        assert_eq!(Key::Char('0').vk(), (0x30, false));
        assert_eq!(Key::F(12).vk(), (0x7b, false));
        assert_eq!(Key::Left.vk(), (0x25, true));
        let mut vks: Vec<u16> = every_key().iter().map(|k| k.vk().0).collect();
        let n = vks.len();
        vks.sort();
        vks.dedup();
        assert_eq!(vks.len(), n, "virtual keys are unique");
    }

    #[test]
    fn mac_keycodes() {
        assert_eq!(Key::Char('a').mac_keycode(), Some(0x00));
        assert_eq!(Key::Char('z').mac_keycode(), Some(0x06));
        assert_eq!(Key::Char('q').mac_keycode(), Some(0x0c));
        assert_eq!(Key::Char('0').mac_keycode(), Some(0x1d));
        assert_eq!(Key::Char('5').mac_keycode(), Some(0x17));
        assert_eq!(Key::F(1).mac_keycode(), Some(0x7a));
        assert_eq!(Key::Insert.mac_keycode(), None);
        let mut codes: Vec<u16> = every_key().iter().filter_map(|k| k.mac_keycode()).collect();
        let n = codes.len();
        codes.sort();
        codes.dedup();
        assert_eq!(codes.len(), n, "keycodes are unique");
    }

    #[test]
    fn text_keysyms() {
        assert_eq!(char_keysym('a'), 0x61);
        assert_eq!(char_keysym('é'), 0xe9);
        assert_eq!(char_keysym('ğ'), 0x0100_011f);
        assert_eq!(char_keysym('€'), 0x0100_20ac);
        assert_eq!(char_keysym('\n'), 0xff0d);
    }
}
