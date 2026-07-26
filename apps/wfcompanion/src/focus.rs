use x11rb::connection::Connection;
use x11rb::protocol::xproto::{Atom, AtomEnum, ConnectionExt as _, Window};
use x11rb::rust_connection::RustConnection;

const WARFRAME_STEAM_CLASS: &str = "steam_app_230410";

pub(crate) struct FocusDetector {
    connection: RustConnection,
    root: Window,
    active_window_atom: Atom,
    pid_atom: Atom,
}

impl FocusDetector {
    pub(crate) fn connect() -> Result<Self, Box<dyn std::error::Error>> {
        let (connection, screen) = RustConnection::connect(None)?;
        let root = connection.setup().roots[screen].root;
        let active_window_atom = intern_atom(&connection, b"_NET_ACTIVE_WINDOW")?;
        let pid_atom = intern_atom(&connection, b"_NET_WM_PID")?;
        Ok(Self {
            connection,
            root,
            active_window_atom,
            pid_atom,
        })
    }

    pub(crate) fn warframe_is_active(&self, expected_pid: Option<u32>) -> bool {
        self.active_window()
            .is_some_and(|window| self.is_warframe_window(window, expected_pid))
    }

    fn active_window(&self) -> Option<Window> {
        self.connection
            .get_property(
                false,
                self.root,
                self.active_window_atom,
                AtomEnum::WINDOW,
                0,
                1,
            )
            .ok()?
            .reply()
            .ok()?
            .value32()?
            .next()
            .filter(|window| *window != x11rb::NONE)
    }

    fn is_warframe_window(&self, window: Window, expected_pid: Option<u32>) -> bool {
        let pid_matches =
            expected_pid.is_some_and(|expected| self.window_pid(window) == Some(expected));
        pid_matches
            || self
                .window_classes(window)
                .any(|class| is_warframe_class(&class))
    }

    fn window_pid(&self, window: Window) -> Option<u32> {
        self.connection
            .get_property(false, window, self.pid_atom, AtomEnum::CARDINAL, 0, 1)
            .ok()?
            .reply()
            .ok()?
            .value32()?
            .next()
    }

    fn window_classes(&self, window: Window) -> impl Iterator<Item = String> {
        let value = self
            .connection
            .get_property(
                false,
                window,
                AtomEnum::WM_CLASS,
                AtomEnum::STRING,
                0,
                u32::MAX,
            )
            .ok()
            .and_then(|cookie| cookie.reply().ok())
            .map(|reply| reply.value)
            .unwrap_or_default();
        value
            .split(|byte| *byte == 0)
            .filter(|class| !class.is_empty())
            .map(|class| String::from_utf8_lossy(class).to_ascii_lowercase())
            .collect::<Vec<_>>()
            .into_iter()
    }
}

fn is_warframe_class(class: &str) -> bool {
    class.eq_ignore_ascii_case(WARFRAME_STEAM_CLASS)
}

fn intern_atom(
    connection: &RustConnection,
    name: &[u8],
) -> Result<Atom, Box<dyn std::error::Error>> {
    Ok(connection.intern_atom(false, name)?.reply()?.atom)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_only_warframe_steam_window_class() {
        assert!(is_warframe_class("steam_app_230410"));
        assert!(is_warframe_class("STEAM_APP_230410"));
        assert!(!is_warframe_class("Tabletop Simulator.x86_64"));
        assert!(!is_warframe_class("steam_app_286160"));
    }
}
