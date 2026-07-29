# Desktop GUI

The desktop GUI should be a separate daemon client. It owns windows, navigation, selection, and
other presentation state. `wfdaemon` remains the source of canonical worldstate, catalogs, player
snapshots, market data, assets, persistence, and queries. `wfcompanion` remains the game observer
and overlay.

## Requirements

AlecaFrame-sized coverage needs:

- virtualized inventory grids, tables, and long lists;
- sorting, filtering, keyboard navigation, and accessible controls;
- asynchronous cached images and item detail views;
- planners, charts, modals, notifications, and Market account workflows;
- KDE Wayland fractional scaling and clean daemon reconnect behavior.

Do not reuse the manual Blend2D overlay renderer for desktop screens. Its narrow scene model is
appropriate for small game overlays, not a general application toolkit.

## Stack

Start with a small Slint and Rust prototype. Slint supplies a declarative UI language, Rust models,
virtualized lists, table widgets, Wayland support through `winit`, and GPU or software renderers.
It fits the existing Cargo workspace without adding a browser frontend. Its royalty-free desktop
license requires attribution; GPLv3 is the other free distribution option.

Prototype one inventory screen before committing to it:

- 5,000 item cards and a 20,000-row table;
- live filter and sort;
- cached remote images;
- keyboard-only operation and screen-reader inspection;
- 100%, 125%, and 150% scaling on KDE Wayland;
- daemon disconnect, restart, and resubscription.

Use Qt 6 and QML if Slint fails the desktop-widget or accessibility checks. Qt has the more mature
model/view, input, accessibility, and deployment surface, including reusable `ListView` and
`GridView` delegates. Cost is a second native build system, Qt packaging, and a C++ or third-party
Rust binding boundary.

Tauri is viable when rapid HTML/CSS implementation outweighs runtime consistency. It uses Rust
plus an OS webview and requires WebKitGTK on Linux. That adds a JavaScript build and platform
webview behavior, so it is not the first choice for this repository.

Iced remains experimental according to its own documentation. GTK would make Linux integration
easy but weakens cross-platform options. Neither is a better initial fit.

## Code Placement

Add the GUI under `apps/` only after the prototype passes. Once a second Rust daemon client exists,
extract the Unix JSON protocol, handshake, reconnect, and subscription code from `wfcompanion`
into one small workspace crate. Keep app-specific requests and state in each client.

## References

- [Slint Rust API](https://docs.slint.dev/latest/docs/rust/slint/)
- [Slint ListView](https://docs.slint.dev/latest/docs/slint/reference/std-widgets/views/listview/)
- [Slint winit backend](https://docs.slint.dev/latest/docs/slint/guide/backends-and-renderers/backend_winit/)
- [Slint license](https://slint.dev/terms-and-conditions)
- [Qt Quick models and views](https://doc.qt.io/qt-6/qtquick-modelviewsdata-modelview.html)
- [Qt licensing](https://doc.qt.io/qt-6/licensing.html)
- [Tauri architecture](https://v2.tauri.app/concept/architecture/)
- [Tauri Linux prerequisites](https://v2.tauri.app/start/prerequisites/)
