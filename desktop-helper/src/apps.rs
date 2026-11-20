//! Launchable apps: Linux `.desktop` entries, Windows Start menu shortcuts, macOS `.app` bundles.
//!
//! `launch` only accepts an id that the current scan returns, so the agent can't start arbitrary paths.
//! The parsers are platform-independent and tested everywhere.

#![allow(dead_code)] // each platform uses its own part

use crate::protocol::{App, Error, Res};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

const MAX_APPS: usize = 2000;
const MAX_FILE: u64 = 256 * 1024;

pub fn list(lang: Option<&str>) -> Vec<App> {
    let mut apps = scan(lang);
    apps.sort_by_cached_key(|a| (a.name.to_lowercase(), a.id.clone()));
    apps.truncate(MAX_APPS);
    apps
}

/// Starts the app with this id (one of `list()`).
pub fn launch(id: &str) -> Res<()> {
    launch_impl(id)
}

// =====================================================================
// Linux / BSD: freedesktop desktop entries

#[derive(Debug, Default, PartialEq)]
pub struct DesktopEntry {
    pub name: String,
    pub icon: Option<String>,
    pub exec: String,
}

/// Reads the `[Desktop Entry]` group; `None` for entries that aren't shown as launchable apps.
pub fn parse_desktop_entry(text: &str, lang: Option<&str>, desktops: &[String]) -> Option<DesktopEntry> {
    let (full, short) = match lang {
        Some(l) => {
            let full = l.split(['.', '@']).next().unwrap_or(l).to_string();
            let short = full.split('_').next().unwrap_or(&full).to_string();
            (Some(full), Some(short))
        }
        None => (None, None),
    };
    let mut in_group = false;
    let (mut name, mut name_full, mut name_short) = (None, None, None);
    let mut e = DesktopEntry::default();
    let mut is_app = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_group = line == "[Desktop Entry]";
            continue;
        }
        if !in_group || line.starts_with('#') {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else { continue };
        let (k, v) = (k.trim(), v.trim());
        match k {
            "Type" => is_app = v == "Application",
            "Name" => name = Some(unescape(v)),
            "Icon" => e.icon = Some(v.to_string()).filter(|s| !s.is_empty()),
            "Exec" => e.exec = unescape(v),
            "NoDisplay" | "Hidden" | "Terminal" if v == "true" => return None,
            "OnlyShowIn" if !desktops.is_empty() && !v.split(';').any(|d| desktops.iter().any(|c| c == d)) => {
                return None;
            }
            "NotShowIn" if v.split(';').any(|d| !d.is_empty() && desktops.iter().any(|c| c == d)) => return None,
            "TryExec" if !v.is_empty() && !exec_exists(v) => return None,
            _ => {
                if let Some(loc) = k.strip_prefix("Name[").and_then(|r| r.strip_suffix(']')) {
                    let loc = loc.split(['.', '@']).next().unwrap_or(loc);
                    if full.as_deref() == Some(loc) {
                        name_full = Some(unescape(v));
                    } else if short.as_deref() == Some(loc) {
                        name_short = Some(unescape(v));
                    }
                }
            }
        }
    }
    e.name = name_full.or(name_short).or(name)?;
    (is_app && !e.exec.is_empty() && !e.name.is_empty()).then_some(e)
}

fn exec_exists(v: &str) -> bool {
    if v.contains('/') { Path::new(v).is_file() } else { crate::util::which(v).is_some() }
}

/// String-level escapes of desktop entry values.
fn unescape(v: &str) -> String {
    let mut out = String::with_capacity(v.len());
    let mut it = v.chars();
    while let Some(c) = it.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match it.next() {
            Some('s') => out.push(' '),
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('r') => out.push('\r'),
            Some('\\') => out.push('\\'),
            Some(o) => {
                out.push('\\');
                out.push(o);
            }
            None => out.push('\\'),
        }
    }
    out
}

/// Splits an `Exec` value into argv: quoting per the spec, field codes (`%f`, `%U`, …) dropped, `%%` → `%`.
pub fn split_exec(exec: &str) -> Option<Vec<String>> {
    let mut args = Vec::new();
    let mut cur = String::new();
    let mut has = false;
    let mut it = exec.chars().peekable();
    while let Some(c) = it.next() {
        match c {
            ' ' | '\t' => {
                if has {
                    args.push(std::mem::take(&mut cur));
                    has = false;
                }
            }
            '"' => {
                has = true;
                loop {
                    match it.next()? {
                        '"' => break,
                        '\\' => match it.next()? {
                            q @ ('"' | '`' | '$' | '\\') => cur.push(q),
                            o => {
                                cur.push('\\');
                                cur.push(o);
                            }
                        },
                        o => cur.push(o),
                    }
                }
            }
            '%' => match it.next() {
                Some('%') => {
                    cur.push('%');
                    has = true;
                }
                // A field code standing alone is dropped entirely; inside a word it just disappears.
                Some(_) => {}
                None => return None,
            },
            o => {
                cur.push(o);
                has = true;
            }
        }
    }
    if has {
        args.push(cur);
    }
    (!args.is_empty()).then_some(args)
}

#[cfg(all(unix, not(target_os = "macos")))]
fn app_dirs() -> Vec<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let data_home = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| home.map(|h| h.join(".local/share")));
    let data_dirs = std::env::var("XDG_DATA_DIRS").ok().filter(|s| !s.is_empty());
    let data_dirs = data_dirs.as_deref().unwrap_or("/usr/local/share:/usr/share");
    data_home
        .into_iter()
        .chain(data_dirs.split(':').map(PathBuf::from).filter(|p| p.is_absolute()))
        .map(|d| d.join("applications"))
        .collect()
}

/// (desktop file id, path) for every entry; earlier directories win.
#[cfg(all(unix, not(target_os = "macos")))]
fn desktop_files(dirs: &[PathBuf]) -> Vec<(String, PathBuf)> {
    fn walk(base: &Path, dir: &Path, depth: u32, seen: &mut HashSet<String>, out: &mut Vec<(String, PathBuf)>) {
        let Ok(rd) = fs::read_dir(dir) else { return };
        for ent in rd.flatten() {
            let p = ent.path();
            let Ok(ft) = ent.file_type() else { continue };
            if ft.is_dir() && depth < 3 {
                walk(base, &p, depth + 1, seen, out);
            } else if p.extension().is_some_and(|e| e == "desktop") {
                let Ok(rel) = p.strip_prefix(base) else { continue };
                let id = rel.to_string_lossy().replace('/', "-");
                if seen.insert(id.clone()) {
                    out.push((id, p));
                }
            }
        }
    }
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for d in dirs {
        walk(d, d, 0, &mut seen, &mut out);
    }
    out
}

#[cfg(all(unix, not(target_os = "macos")))]
fn current_desktops() -> Vec<String> {
    std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default().split(':').filter(|s| !s.is_empty()).map(String::from).collect()
}

#[cfg(all(unix, not(target_os = "macos")))]
fn read_entry(path: &Path, lang: Option<&str>, desktops: &[String]) -> Option<DesktopEntry> {
    let meta = fs::metadata(path).ok()?;
    if meta.len() > MAX_FILE {
        return None;
    }
    parse_desktop_entry(&fs::read_to_string(path).ok()?, lang, desktops)
}

#[cfg(all(unix, not(target_os = "macos")))]
fn scan(lang: Option<&str>) -> Vec<App> {
    let lang = lang.map(String::from).or_else(|| std::env::var("LANG").ok());
    scan_dirs(&app_dirs(), lang.as_deref(), &current_desktops())
}

#[cfg(all(unix, not(target_os = "macos")))]
fn scan_dirs(dirs: &[PathBuf], lang: Option<&str>, desktops: &[String]) -> Vec<App> {
    desktop_files(dirs)
        .into_iter()
        .filter_map(|(id, p)| {
            let e = read_entry(&p, lang, desktops)?;
            Some(App { id, name: e.name, icon: e.icon })
        })
        .collect()
}

#[cfg(all(unix, not(target_os = "macos")))]
fn launch_impl(id: &str) -> Res<()> {
    launch_in(&app_dirs(), id, &current_desktops())
}

#[cfg(all(unix, not(target_os = "macos")))]
fn launch_in(dirs: &[PathBuf], id: &str, desktops: &[String]) -> Res<()> {
    let (_, path) = desktop_files(dirs).into_iter().find(|(i, _)| i == id).ok_or_else(|| Error::not_found("no such app"))?;
    let e = read_entry(&path, None, desktops).ok_or_else(|| Error::not_found("no such app"))?;
    let argv = split_exec(&e.exec).ok_or_else(|| Error::failed("the app's Exec line can't be parsed"))?;
    crate::util::spawn_detached(argv[0].as_ref(), &argv[1..])
}

// =====================================================================
// Windows: Start menu shortcuts

#[cfg(windows)]
fn start_menu_links() -> Vec<PathBuf> {
    fn walk(dir: &Path, depth: u32, out: &mut Vec<PathBuf>) {
        let Ok(rd) = fs::read_dir(dir) else { return };
        for ent in rd.flatten() {
            let p = ent.path();
            let Ok(ft) = ent.file_type() else { continue };
            if ft.is_dir() && depth < 4 {
                walk(&p, depth + 1, out);
            } else if p.extension().is_some_and(|e| e.eq_ignore_ascii_case("lnk")) {
                out.push(p);
            }
        }
    }
    let mut out = Vec::new();
    for var in ["ProgramData", "APPDATA"] {
        if let Some(base) = std::env::var_os(var) {
            walk(&PathBuf::from(base).join(r"Microsoft\Windows\Start Menu\Programs"), 0, &mut out);
        }
    }
    out
}

/// Shortcut names that aren't apps a user wants to start remotely.
fn is_noise(name: &str) -> bool {
    let n = name.to_lowercase();
    ["uninstall", "kaldır", "readme", "release notes", "help"].iter().any(|w| n.contains(w))
}

#[cfg(windows)]
fn scan(_lang: Option<&str>) -> Vec<App> {
    let mut seen = HashSet::new();
    start_menu_links()
        .into_iter()
        .filter_map(|p| {
            let name = p.file_stem()?.to_string_lossy().into_owned();
            if is_noise(&name) || !seen.insert(name.to_lowercase()) {
                return None;
            }
            Some(App { id: p.to_string_lossy().into_owned(), name, icon: None })
        })
        .collect()
}

#[cfg(windows)]
fn launch_impl(id: &str) -> Res<()> {
    let p = start_menu_links().into_iter().find(|p| p.to_string_lossy() == id).ok_or_else(|| Error::not_found("no such app"))?;
    crate::backend::windows::shell_open(&p)
}

// =====================================================================
// macOS: application bundles

/// `CFBundleDisplayName` or `CFBundleName` from an XML Info.plist (binary plists fall back to the bundle name).
pub fn plist_name(xml: &str) -> Option<String> {
    let value = |key: &str| {
        let i = xml.find(&format!("<key>{key}</key>"))?;
        let rest = &xml[i..];
        let s = rest.find("<string>")? + "<string>".len();
        let e = rest[s..].find("</string>")?;
        // Only the value right after the key: no other <key> in between.
        if rest[..s].matches("<key>").count() != 1 {
            return None;
        }
        let v = rest[s..s + e].trim().replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">");
        (!v.is_empty() && !v.contains("$(")).then_some(v)
    };
    value("CFBundleDisplayName").or_else(|| value("CFBundleName"))
}

#[cfg(target_os = "macos")]
fn bundles() -> Vec<PathBuf> {
    let mut dirs = vec![
        PathBuf::from("/Applications"),
        PathBuf::from("/Applications/Utilities"),
        PathBuf::from("/System/Applications"),
        PathBuf::from("/System/Applications/Utilities"),
    ];
    if let Some(h) = std::env::var_os("HOME") {
        dirs.push(PathBuf::from(h).join("Applications"));
    }
    let mut out = Vec::new();
    for d in dirs {
        let Ok(rd) = fs::read_dir(&d) else { continue };
        out.extend(rd.flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|e| e == "app")));
    }
    out
}

#[cfg(target_os = "macos")]
fn scan(_lang: Option<&str>) -> Vec<App> {
    let mut seen = HashSet::new();
    bundles()
        .into_iter()
        .filter_map(|p| {
            let stem = p.file_stem()?.to_string_lossy().into_owned();
            let plist = p.join("Contents/Info.plist");
            let name = fs::metadata(&plist)
                .ok()
                .filter(|m| m.len() <= MAX_FILE)
                .and_then(|_| fs::read_to_string(&plist).ok())
                .and_then(|x| plist_name(&x))
                .unwrap_or(stem);
            seen.insert(p.clone()).then(|| App { id: p.to_string_lossy().into_owned(), name, icon: None })
        })
        .collect()
}

#[cfg(target_os = "macos")]
fn launch_impl(id: &str) -> Res<()> {
    let p = bundles().into_iter().find(|p| p.to_string_lossy() == id).ok_or_else(|| Error::not_found("no such app"))?;
    crate::util::run_ok("open", &[p.as_os_str()], None).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIREFOX: &str = "[Desktop Entry]\nName=Firefox\nName[tr]=Firefox Tarayıcı\nName[pt_BR]=Navegador\nIcon=firefox\nExec=firefox %u\nType=Application\n\n[Desktop Action new-window]\nName=New Window\nExec=firefox --new-window %u\n";

    #[test]
    fn desktop_entries() {
        let e = parse_desktop_entry(FIREFOX, None, &[]).unwrap();
        assert_eq!(e, DesktopEntry { name: "Firefox".into(), icon: Some("firefox".into()), exec: "firefox %u".into() });
        assert_eq!(parse_desktop_entry(FIREFOX, Some("tr_TR.UTF-8"), &[]).unwrap().name, "Firefox Tarayıcı");
        assert_eq!(parse_desktop_entry(FIREFOX, Some("pt_BR"), &[]).unwrap().name, "Navegador");
        assert_eq!(parse_desktop_entry(FIREFOX, Some("de"), &[]).unwrap().name, "Firefox");
        let hidden = FIREFOX.replace("Type=Application", "Type=Application\nNoDisplay=true");
        assert!(parse_desktop_entry(&hidden, None, &[]).is_none());
        let term = FIREFOX.replace("Type=Application", "Type=Application\nTerminal=true");
        assert!(parse_desktop_entry(&term, None, &[]).is_none());
        let link = FIREFOX.replace("Type=Application", "Type=Link");
        assert!(parse_desktop_entry(&link, None, &[]).is_none());
        let only = FIREFOX.replace("Type=Application", "Type=Application\nOnlyShowIn=KDE;");
        assert!(parse_desktop_entry(&only, None, &["GNOME".into()]).is_none());
        assert!(parse_desktop_entry(&only, None, &["KDE".into()]).is_some());
        let not = FIREFOX.replace("Type=Application", "Type=Application\nNotShowIn=GNOME;");
        assert!(parse_desktop_entry(&not, None, &["GNOME".into()]).is_none());
        let tried = FIREFOX.replace("Type=Application", "Type=Application\nTryExec=surely-not-installed-xyz");
        assert!(parse_desktop_entry(&tried, None, &[]).is_none());
        // The action group's Exec doesn't override the main one.
        assert_eq!(parse_desktop_entry(FIREFOX, None, &[]).unwrap().exec, "firefox %u");
    }

    #[test]
    fn exec_lines() {
        let v = |s: &str| split_exec(s).map(|a| a.into_iter().collect::<Vec<_>>());
        assert_eq!(v("firefox %u"), Some(vec!["firefox".into()]));
        assert_eq!(v("env FOO=1 app --x=%f"), Some(vec!["env".into(), "FOO=1".into(), "app".into(), "--x=".into()]));
        assert_eq!(v(r#""/opt/My App/bin" --name "a \"b\"" 100%%"#), Some(vec!["/opt/My App/bin".into(), "--name".into(), "a \"b\"".into(), "100%".into()]));
        assert_eq!(v(r#""unterminated"#), None);
        assert_eq!(v("   "), None);
        assert_eq!(v(r#""""#), Some(vec![String::new()]));
        assert_eq!(unescape(r"a\sb\\c"), r"a b\c");
    }

    #[test]
    fn plist_names() {
        let x = "<dict><key>CFBundleName</key><string>Safari</string><key>CFBundleDisplayName</key>\n<string>Safari Browser</string></dict>";
        assert_eq!(plist_name(x), Some("Safari Browser".into()));
        let y = "<dict><key>CFBundleName</key><string>A &amp; B</string></dict>";
        assert_eq!(plist_name(y), Some("A & B".into()));
        let z = "<dict><key>CFBundleName</key><key>Other</key><string>x</string></dict>";
        assert_eq!(plist_name(z), None);
        assert_eq!(plist_name("bplist00..."), None);
        assert_eq!(plist_name("<key>CFBundleName</key><string>$(PRODUCT_NAME)</string>"), None);
    }

    #[test]
    fn noise() {
        assert!(is_noise("Uninstall Foo"));
        assert!(!is_noise("Visual Studio Code"));
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    #[test]
    fn scans_a_data_dir() {
        let tmp = std::env::temp_dir().join(format!("tiphys-apps-{}", std::process::id()));
        let (user, system) = (tmp.join("user"), tmp.join("system"));
        fs::create_dir_all(user.join("sub")).unwrap();
        fs::create_dir_all(&system).unwrap();
        fs::write(user.join("sub/t.desktop"), FIREFOX).unwrap();
        fs::write(system.join("sub-t.desktop"), FIREFOX.replace("Name=Firefox", "Name=Shadowed")).unwrap();
        fs::write(system.join("hidden.desktop"), FIREFOX.replace("Type=Application", "Type=Application\nHidden=true")).unwrap();
        let dirs = [user, system];
        let list = scan_dirs(&dirs, None, &[]);
        assert_eq!(list, vec![App { id: "sub-t.desktop".into(), name: "Firefox".into(), icon: Some("firefox".into()) }]);
        assert_eq!(launch_in(&dirs, "nope.desktop", &[]).unwrap_err().code, crate::protocol::Code::NotFound);
        assert_eq!(launch_in(&dirs, "hidden.desktop", &[]).unwrap_err().code, crate::protocol::Code::NotFound);
        fs::remove_dir_all(&tmp).unwrap();
    }
}
