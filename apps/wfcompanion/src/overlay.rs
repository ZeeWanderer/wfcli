use std::collections::BTreeMap;
use std::fs;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant};

use fontdue::Font;
use image::ImageFormat;
use serde_json::Value;
use smithay_client_toolkit::compositor::{CompositorHandler, CompositorState, Region};
use smithay_client_toolkit::delegate_compositor;
use smithay_client_toolkit::delegate_layer;
use smithay_client_toolkit::delegate_output;
use smithay_client_toolkit::delegate_pointer;
use smithay_client_toolkit::delegate_registry;
use smithay_client_toolkit::delegate_seat;
use smithay_client_toolkit::delegate_shm;
use smithay_client_toolkit::output::{OutputHandler, OutputState};
use smithay_client_toolkit::reexports::calloop::{EventLoop, LoopSignal};
use smithay_client_toolkit::reexports::calloop_wayland_source::WaylandSource;
use smithay_client_toolkit::registry::{ProvidesRegistryState, RegistryState};
use smithay_client_toolkit::registry_handlers;
use smithay_client_toolkit::seat::pointer::{
    BTN_LEFT, CursorIcon, PointerEvent, PointerEventKind, PointerHandler, ThemeSpec, ThemedPointer,
};
use smithay_client_toolkit::seat::{Capability, SeatHandler, SeatState};
use smithay_client_toolkit::shell::WaylandSurface;
use smithay_client_toolkit::shell::wlr_layer::{
    Anchor, KeyboardInteractivity, Layer, LayerShell, LayerShellHandler, LayerSurface,
    LayerSurfaceConfigure,
};
use smithay_client_toolkit::shm::slot::{Buffer, SlotPool};
use smithay_client_toolkit::shm::{Shm, ShmHandler};
use wayland_client::globals::registry_queue_init;
use wayland_client::protocol::{wl_output, wl_pointer, wl_seat, wl_shm, wl_surface};
use wayland_client::{Connection, QueueHandle};

use crate::UiEvent;
use crate::focus::FocusDetector;
use crate::incident;
use crate::painter::{
    Painter, RasterImage, TextBox, css_rgba, fit_text_size, load_icon, load_overlay_font,
    straight_rgba, text_width,
};
use crate::ui_layout::{Rect, RelicCardSpec, RelicLayout, relic_layout, relic_suggestion_layout};

const WIDTH: u32 = 420;
const HEIGHT: u32 = 90;
const STATUS_INSET: u32 = 16;
const STATUS_SURFACE_WIDTH: u32 = WIDTH + STATUS_INSET;
const STATUS_SURFACE_HEIGHT: u32 = HEIGHT + STATUS_INSET;
const EVENT_INTERVAL: Duration = Duration::from_millis(50);
const FOCUS_INTERVAL: Duration = Duration::from_millis(100);
const LOADING_FPS: u64 = 30;
const LOADING_FRAME_INTERVAL: Duration = Duration::from_nanos(1_000_000_000 / LOADING_FPS);
const LOADING_CYCLE: f32 = 1.923_076_9;
const LOADING_RADIUS: u32 = 24;
const LOADING_STROKE: u32 = 6;
const MAX_SURFACE_BUFFERS: usize = 3;
const MAX_DECODED_ASSETS: usize = 128;
const DEBUG_HUD: bool = cfg!(debug_assertions);

pub(crate) fn run(
    events: mpsc::Receiver<UiEvent>,
    shortcut: crate::shortcut::Controller,
    stopping: Arc<AtomicBool>,
) -> Result<(), Box<dyn std::error::Error>> {
    let connection = Connection::connect_to_env()?;
    let (globals, event_queue) = registry_queue_init(&connection)?;
    let queue_handle = event_queue.handle();
    let mut event_loop: EventLoop<Overlay> = EventLoop::try_new()?;
    WaylandSource::new(connection.clone(), event_queue).insert(event_loop.handle())?;

    let compositor = CompositorState::bind(&globals, &queue_handle)?;
    let layer_shell = LayerShell::bind(&globals, &queue_handle)?;
    let shm = Shm::bind(&globals, &queue_handle)?;
    let surface = compositor.create_surface(&queue_handle);
    let layer = layer_shell.create_layer_surface(
        &queue_handle,
        surface,
        Layer::Overlay,
        Some("wfcompanion"),
        None,
    );
    apply_layer_state(&layer, false);
    let empty_input_region = Region::new(&compositor)?;
    let interactive_input_region = Region::new(&compositor)?;
    interactive_input_region.add(0, 0, i32::MAX, i32::MAX);
    layer
        .wl_surface()
        .set_input_region(Some(empty_input_region.wl_region()));
    layer.commit();

    let pool = SlotPool::new(
        (STATUS_SURFACE_WIDTH * STATUS_SURFACE_HEIGHT * 4) as usize,
        &shm,
    )?;
    let font = load_overlay_font()?;
    let platinum_icon = load_icon(include_bytes!("../assets/platinum.png"))?;
    let ducat_icon = load_icon(include_bytes!("../assets/ducats.png"))?;
    let suggestion_icons = SuggestionIcons::load()?;
    let asset_images = embedded_part_images()?;
    let loop_signal = event_loop.get_signal();
    let mut overlay = Overlay {
        registry_state: RegistryState::new(&globals),
        seat_state: SeatState::new(&globals, &queue_handle),
        output_state: OutputState::new(&globals, &queue_handle),
        compositor,
        shm,
        layer,
        empty_input_region,
        interactive_input_region,
        themed_pointer: None,
        font,
        platinum_icon,
        ducat_icon,
        suggestion_icons,
        pool,
        buffers: Vec::new(),
        width: STATUS_SURFACE_WIDTH,
        height: STATUS_SURFACE_HEIGHT,
        scale: 1,
        configured: false,
        configure_pending: true,
        mapped: false,
        redraw: Redraw::Full,
        overlay_enabled: true,
        hud_visible: DEBUG_HUD,
        contextual_surface: false,
        warframe_active: false,
        warframe_pid: None,
        connected: false,
        snapshots: BTreeMap::new(),
        connection_error: None,
        relic_scene: None,
        relic_frame_cache: None,
        asset_images,
        last_loading_frame: Instant::now() - LOADING_FRAME_INTERVAL,
        frame_pending: false,
        interaction_active: false,
        shortcut_scope: false,
        suggestion_offset: 0,
        close_hovered: false,
        scroll_accumulator: 0.0,
        events,
        shortcut,
        stopping,
        focus: FocusDetector::connect().ok(),
        last_focus_check: Instant::now() - FOCUS_INTERVAL,
        loop_signal,
    };

    while !overlay.stopping.load(Ordering::Relaxed) {
        event_loop.dispatch(overlay.dispatch_interval(), &mut overlay)?;
        overlay.tick(&queue_handle);
    }
    overlay.shortcut.set_enabled(false);
    overlay.unmap();
    Ok(())
}

pub(crate) fn save_relic_preview(dimensions: (u32, u32), path: &Path) -> Result<(), String> {
    save_preview_image(
        render_relic_scene_preview(dimensions, &mock_relic_scene(), Duration::ZERO)?,
        path,
    )
}

pub(crate) fn save_relic_loading_preview(
    dimensions: (u32, u32),
    path: &Path,
) -> Result<(), String> {
    save_preview_image(
        render_relic_loading_preview(dimensions, Duration::from_millis(750))?,
        path,
    )
}

pub(crate) fn save_relic_suggestions_preview(
    dimensions: (u32, u32),
    path: &Path,
) -> Result<(), String> {
    let scene = crate::relic::suggestion_fixture()?;
    save_preview_image(
        render_relic_scene_preview(dimensions, &scene, Duration::ZERO)?,
        path,
    )
}

pub(crate) fn save_notification_preview(dimensions: (u32, u32), path: &Path) -> Result<(), String> {
    save_preview_image(render_notification_preview(dimensions)?, path)
}

pub(crate) fn render_relic_loading_preview(
    dimensions: (u32, u32),
    elapsed: Duration,
) -> Result<image::RgbaImage, String> {
    render_relic_scene_preview(dimensions, &crate::relic::Scene::Reading, elapsed)
}

fn render_relic_scene_preview(
    dimensions: (u32, u32),
    scene: &crate::relic::Scene,
    elapsed: Duration,
) -> Result<image::RgbaImage, String> {
    let (width, height) = dimensions;
    let mut overlay = vec![0; (width * height * 4) as usize];
    let font =
        load_overlay_font().map_err(|error| format!("could not load overlay font: {error}"))?;
    let platinum_icon = load_icon(include_bytes!("../assets/platinum.png"))
        .map_err(|error| format!("could not load platinum icon: {error}"))?;
    let ducat_icon = load_icon(include_bytes!("../assets/ducats.png"))
        .map_err(|error| format!("could not load ducat icon: {error}"))?;
    let suggestion_icons = SuggestionIcons::load()
        .map_err(|error| format!("could not load suggestion icons: {error}"))?;
    let mut painter = Painter::new(&mut overlay, width, height)
        .map_err(|error| format!("could not create overlay painter: {error}"))?;
    let asset_images =
        embedded_part_images().map_err(|error| format!("could not load part icons: {error}"))?;
    draw_relic_scene(
        &mut painter,
        &font,
        &platinum_icon,
        &ducat_icon,
        &suggestion_icons,
        &asset_images,
        1,
        scene,
        elapsed,
        0,
        false,
        false,
    );
    painter
        .finish()
        .map_err(|error| format!("could not render overlay: {error}"))?;

    straight_rgba(&overlay, width, height)
}

fn render_notification_preview(dimensions: (u32, u32)) -> Result<image::RgbaImage, String> {
    let mut surface = vec![0; (WIDTH * HEIGHT * 4) as usize];
    let font =
        load_overlay_font().map_err(|error| format!("could not load overlay font: {error}"))?;
    let mut painter = Painter::new(&mut surface, WIDTH, HEIGHT)
        .map_err(|error| format!("could not create overlay painter: {error}"))?;
    painter.clear();
    draw_status(
        &mut painter,
        &font,
        1,
        0,
        0,
        "wfdaemon 0.1.0 - connected",
        "Warframe running (pid 12345)",
        "wfcli companion hud hide",
    );
    painter
        .finish()
        .map_err(|error| format!("could not render overlay: {error}"))?;

    let (width, height) = dimensions;
    let mut output = vec![0; (width * height * 4) as usize];
    blit_surface(
        &mut output,
        width,
        height,
        &surface,
        WIDTH,
        HEIGHT,
        STATUS_INSET,
        STATUS_INSET,
    );
    straight_rgba(&output, width, height)
}

fn save_preview_image(output: image::RgbaImage, path: &Path) -> Result<(), String> {
    output
        .save_with_format(path, ImageFormat::Png)
        .map_err(|error| format!("could not write {}: {error}", path.display()))?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn blit_surface(
    target: &mut [u8],
    target_width: u32,
    target_height: u32,
    source: &[u8],
    source_width: u32,
    source_height: u32,
    x: u32,
    y: u32,
) {
    let copy_width = source_width.min(target_width.saturating_sub(x));
    let copy_height = source_height.min(target_height.saturating_sub(y));
    for row in 0..copy_height {
        let source_start = (row * source_width * 4) as usize;
        let target_start = (((y + row) * target_width + x) * 4) as usize;
        let bytes = (copy_width * 4) as usize;
        target[target_start..target_start + bytes]
            .copy_from_slice(&source[source_start..source_start + bytes]);
    }
}

fn copy_frame_rect(source: &[u8], target: &mut [u8], frame_width: u32, bounds: Rect) {
    let stride = frame_width as usize * 4;
    let row_bytes = bounds.width as usize * 4;
    let x = bounds.x as usize * 4;
    for row in bounds.y as usize..(bounds.y + bounds.height) as usize {
        let start = row * stride + x;
        target[start..start + row_bytes].copy_from_slice(&source[start..start + row_bytes]);
    }
}

struct SuggestionIcons {
    trace: RasterImage,
    vaulted: RasterImage,
    close: RasterImage,
}

impl SuggestionIcons {
    fn load() -> Result<Self, Box<dyn std::error::Error>> {
        Ok(Self {
            trace: load_icon(include_bytes!("../assets/trace.png"))?,
            vaulted: load_icon(include_bytes!("../assets/vaulted.png"))?,
            close: load_icon(include_bytes!("../assets/close.png"))?,
        })
    }
}

fn embedded_part_images() -> Result<BTreeMap<String, RasterImage>, Box<dyn std::error::Error>> {
    let mut images = BTreeMap::new();
    for asset in crate::assets::EMBEDDED_PART_ASSETS {
        if !images.contains_key(asset.image.key) {
            images.insert(asset.image.key.to_owned(), load_icon(asset.image.bytes)?);
        }
    }
    Ok(images)
}

struct Overlay {
    registry_state: RegistryState,
    seat_state: SeatState,
    output_state: OutputState,
    compositor: CompositorState,
    shm: Shm,
    layer: LayerSurface,
    empty_input_region: Region,
    interactive_input_region: Region,
    themed_pointer: Option<ThemedPointer>,
    font: Font,
    platinum_icon: RasterImage,
    ducat_icon: RasterImage,
    suggestion_icons: SuggestionIcons,
    pool: SlotPool,
    buffers: Vec<SurfaceBuffer>,
    width: u32,
    height: u32,
    scale: i32,
    configured: bool,
    configure_pending: bool,
    mapped: bool,
    redraw: Redraw,
    overlay_enabled: bool,
    hud_visible: bool,
    contextual_surface: bool,
    warframe_active: bool,
    warframe_pid: Option<u32>,
    connected: bool,
    snapshots: BTreeMap<String, Value>,
    connection_error: Option<String>,
    relic_scene: Option<(crate::relic::Scene, Option<Instant>, Instant)>,
    relic_frame_cache: Option<RelicFrameCache>,
    asset_images: BTreeMap<String, RasterImage>,
    last_loading_frame: Instant,
    frame_pending: bool,
    interaction_active: bool,
    shortcut_scope: bool,
    suggestion_offset: usize,
    close_hovered: bool,
    scroll_accumulator: f64,
    events: mpsc::Receiver<UiEvent>,
    shortcut: crate::shortcut::Controller,
    stopping: Arc<AtomicBool>,
    focus: Option<FocusDetector>,
    last_focus_check: Instant,
    loop_signal: LoopSignal,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct RelicFrameKey {
    width: u32,
    height: u32,
    scale: u32,
    scene: crate::relic::Scene,
    suggestion_offset: usize,
    interaction_active: bool,
    close_hovered: bool,
}

struct RelicFrameCache {
    key: RelicFrameKey,
    pixels: Vec<u8>,
    animation_bounds: Option<Rect>,
}

struct SurfaceBuffer {
    buffer: Buffer,
    frame_key: Option<RelicFrameKey>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Redraw {
    None,
    Loading,
    Full,
}

impl Overlay {
    fn dispatch_interval(&self) -> Duration {
        if self.loading_active() && !self.frame_pending {
            EVENT_INTERVAL
                .min(LOADING_FRAME_INTERVAL.saturating_sub(self.last_loading_frame.elapsed()))
        } else {
            EVENT_INTERVAL
        }
    }

    fn loading_active(&self) -> bool {
        self.overlay_enabled
            && self.warframe_active
            && self
                .relic_scene
                .as_ref()
                .is_some_and(|(scene, _, _)| matches!(scene, crate::relic::Scene::Reading))
    }

    fn request_full_redraw(&mut self) {
        self.redraw = Redraw::Full;
    }

    fn request_loading_redraw(&mut self) {
        if self.redraw == Redraw::None {
            self.redraw = Redraw::Loading;
        }
    }

    fn tick(&mut self, queue_handle: &QueueHandle<Self>) {
        self.apply_events();
        self.expire_scene();
        self.update_focus();
        self.sync_shortcut_scope();
        self.animate_loading();
        self.sync_surface(queue_handle);
    }

    fn apply_events(&mut self) {
        while let Ok(event) = self.events.try_recv() {
            match event {
                UiEvent::Connected(daemon) => {
                    self.connected = true;
                    self.connection_error = None;
                    self.snapshots.insert("daemon".to_owned(), daemon);
                    self.request_full_redraw();
                }
                UiEvent::Disconnected(error) => {
                    self.connected = false;
                    self.connection_error = Some(error);
                    self.request_full_redraw();
                }
                UiEvent::Snapshot { dataset, data } => {
                    if dataset == "player" {
                        self.warframe_pid = data
                            .get("data")
                            .and_then(|data| data.get("game"))
                            .and_then(|game| game.get("pid"))
                            .and_then(Value::as_u64)
                            .and_then(|pid| u32::try_from(pid).ok());
                    }
                    self.snapshots.insert(dataset, data);
                    self.request_full_redraw();
                }
                UiEvent::OverlayVisible(visible) => {
                    self.overlay_enabled = visible;
                    incident::info("overlay.visibility", format!("enabled={visible}"));
                    self.request_full_redraw();
                }
                UiEvent::HudVisible(visible) => {
                    self.hud_visible = visible;
                    incident::info("overlay.hud", format!("visible={visible}"));
                    self.request_full_redraw();
                }
                UiEvent::RelicScene { scene, deadline } => {
                    let now = Instant::now();
                    if !scene_deadline_is_current(deadline, now) {
                        incident::info(
                            "overlay.scene_late",
                            format!("kind={}", scene_name(&scene)),
                        );
                        continue;
                    }
                    let started = self
                        .relic_scene
                        .as_ref()
                        .filter(|(_, current_deadline, _)| *current_deadline == deadline)
                        .map_or(now, |(_, _, started)| *started);
                    let updates_current_suggestions =
                        matches!(scene, crate::relic::Scene::Suggestions(_))
                            && self.relic_scene.as_ref().is_some_and(
                                |(current, current_deadline, _)| {
                                    *current_deadline == deadline
                                        && matches!(current, crate::relic::Scene::Suggestions(_))
                                },
                            );
                    incident::info(
                        "overlay.scene",
                        deadline.map_or_else(
                            || format!("kind={} persistent=true", scene_name(&scene)),
                            |expires| {
                                format!(
                                    "kind={} remaining_ms={}",
                                    scene_name(&scene),
                                    expires.saturating_duration_since(now).as_millis()
                                )
                            },
                        ),
                    );
                    self.cache_scene_assets(&scene);
                    if matches!(scene, crate::relic::Scene::Suggestions(_))
                        && !updates_current_suggestions
                    {
                        self.suggestion_offset = 0;
                    }
                    self.relic_scene = Some((scene, deadline, started));
                    self.request_full_redraw();
                }
                UiEvent::RelicDismiss => {
                    if self.relic_scene.as_ref().is_some_and(|(scene, _, _)| {
                        matches!(scene, crate::relic::Scene::Suggestions(_))
                    }) {
                        incident::info("overlay.scene", "kind=dismissed");
                        self.relic_scene = None;
                        self.request_full_redraw();
                    }
                }
                UiEvent::InteractionToggle => {
                    self.set_interaction(!self.interaction_active);
                }
                UiEvent::Shutdown => {
                    self.set_interaction(false);
                    self.shortcut.set_enabled(false);
                    self.stopping.store(true, Ordering::Relaxed);
                    self.loop_signal.stop();
                }
            }
        }
    }

    fn expire_scene(&mut self) {
        if self
            .relic_scene
            .as_ref()
            .is_some_and(|(_, expires, _)| expires.is_some_and(|expires| Instant::now() >= expires))
        {
            incident::info("overlay.scene_expired", "relic");
            self.relic_scene = None;
            self.request_full_redraw();
        }
    }

    fn cache_scene_assets(&mut self, scene: &crate::relic::Scene) {
        let crate::relic::Scene::Rewards(rewards) = scene else {
            return;
        };
        for asset in rewards.items.iter().flat_map(|reward| {
            reward
                .asset
                .iter()
                .chain(reward.parts.iter().filter_map(|part| part.asset.as_ref()))
        }) {
            if self.asset_images.contains_key(&asset.digest) {
                continue;
            }
            let image = fs::read(&asset.path)
                .map_err(|error| format!("{}: {error}", asset.path))
                .and_then(|bytes| load_icon(&bytes).map_err(|error| error.to_string()));
            match image {
                Ok(image) => {
                    if self.asset_images.len() >= MAX_DECODED_ASSETS
                        && let Some(oldest) = self.asset_images.keys().next().cloned()
                    {
                        self.asset_images.remove(&oldest);
                    }
                    self.asset_images.insert(asset.digest.clone(), image);
                }
                Err(error) => incident::warn(
                    "overlay.asset_decode_failed",
                    format!("id={} error={error}", asset.id),
                ),
            }
        }
    }

    fn animate_loading(&mut self) {
        if !self.loading_active() {
            self.frame_pending = false;
            return;
        }
        if !self.frame_pending && self.last_loading_frame.elapsed() >= LOADING_FRAME_INTERVAL {
            self.last_loading_frame = Instant::now();
            self.request_loading_redraw();
        }
    }

    fn update_focus(&mut self) {
        if self.last_focus_check.elapsed() < FOCUS_INTERVAL {
            return;
        }
        self.last_focus_check = Instant::now();
        let active = self
            .focus
            .as_ref()
            .is_some_and(|focus| focus.warframe_is_active(self.warframe_pid));
        if active != self.warframe_active {
            self.warframe_active = active;
            incident::info("overlay.focus", format!("warframe_active={active}"));
            self.request_full_redraw();
        }
    }

    fn interaction_allowed(&self) -> bool {
        self.overlay_enabled
            && self.warframe_active
            && self.relic_scene.as_ref().is_some_and(|(scene, _, _)| {
                matches!(
                    scene,
                    crate::relic::Scene::Rewards(_) | crate::relic::Scene::Suggestions(_)
                )
            })
    }

    fn sync_shortcut_scope(&mut self) {
        let enabled = self.interaction_allowed();
        if enabled != self.shortcut_scope {
            self.shortcut_scope = enabled;
            self.shortcut.set_enabled(enabled);
        }
        if !enabled {
            self.set_interaction(false);
        }
    }

    fn set_interaction(&mut self, active: bool) {
        let active = active && self.interaction_allowed();
        if active == self.interaction_active {
            return;
        }
        self.interaction_active = active;
        self.close_hovered = false;
        self.scroll_accumulator = 0.0;
        self.layer.wl_surface().set_input_region(Some(if active {
            self.interactive_input_region.wl_region()
        } else {
            self.empty_input_region.wl_region()
        }));
        self.layer.commit();
        incident::info("overlay.interaction", format!("active={active}"));
        self.request_full_redraw();
    }

    fn update_pointer(&mut self, connection: &Connection, position: (f64, f64)) {
        let hovered = self
            .suggestion_layout()
            .is_some_and(|layout| layout.close.contains(position.0, position.1));
        if hovered != self.close_hovered {
            self.close_hovered = hovered;
            self.request_full_redraw();
        }
        if let Some(pointer) = self.themed_pointer.as_ref() {
            let icon = if hovered {
                CursorIcon::Pointer
            } else {
                CursorIcon::Default
            };
            let _ = pointer.set_cursor(connection, icon);
        }
    }

    fn suggestion_layout(&self) -> Option<crate::ui_layout::RelicSuggestionLayout> {
        let count = self.relic_scene.as_ref().and_then(|(scene, _, _)| {
            let crate::relic::Scene::Suggestions(suggestions) = scene else {
                return None;
            };
            Some(
                suggestions
                    .items
                    .len()
                    .saturating_sub(self.suggestion_offset),
            )
        })?;
        Some(relic_suggestion_layout(self.width, self.height, count))
    }

    fn scroll_suggestions(&mut self, delta: f64) {
        let Some(item_count) = self.relic_scene.as_ref().and_then(|(scene, _, _)| {
            let crate::relic::Scene::Suggestions(suggestions) = scene else {
                return None;
            };
            Some(suggestions.items.len())
        }) else {
            return;
        };
        self.scroll_accumulator += delta;
        let rows = self.scroll_accumulator.trunc() as isize;
        if rows == 0 {
            return;
        }
        self.scroll_accumulator -= rows as f64;
        let max_offset = max_suggestion_offset(item_count);
        let next = self
            .suggestion_offset
            .saturating_add_signed(rows.saturating_mul(2))
            .min(max_offset);
        if next != self.suggestion_offset {
            self.suggestion_offset = next;
            self.request_full_redraw();
        }
    }

    fn dismiss_suggestions(&mut self) {
        if self
            .relic_scene
            .as_ref()
            .is_some_and(|(scene, _, _)| matches!(scene, crate::relic::Scene::Suggestions(_)))
        {
            incident::info("overlay.scene", "kind=closed");
            self.relic_scene = None;
            self.set_interaction(false);
            self.request_full_redraw();
        }
    }

    fn sync_surface(&mut self, queue_handle: &QueueHandle<Self>) {
        let scene_visible = self.overlay_enabled && self.relic_scene.is_some();
        let status_visible = self.overlay_enabled && self.hud_visible;
        let contextual = contextual_surface_required(
            self.overlay_enabled,
            scene_visible,
            status_visible,
            self.contextual_surface,
        );
        if self.sync_geometry(contextual) {
            return;
        }
        let should_draw = ((status_visible || scene_visible) && self.warframe_active) || contextual;
        if !self.configured {
            if needs_remap_configure(should_draw, self.configure_pending) {
                apply_layer_state(&self.layer, self.contextual_surface);
                self.layer.commit();
                self.configure_pending = true;
                incident::info("overlay.remap_requested", "waiting for configure");
            }
            return;
        }
        if should_draw {
            if self.redraw != Redraw::None || !self.mapped {
                self.draw(queue_handle);
            }
        } else if self.mapped {
            self.unmap();
        }
    }

    fn sync_geometry(&mut self, contextual: bool) -> bool {
        if self.contextual_surface == contextual {
            return false;
        }
        self.contextual_surface = contextual;
        apply_layer_state(&self.layer, contextual);
        self.layer.commit();
        self.configured = false;
        self.configure_pending = true;
        self.buffers.clear();
        true
    }

    fn unmap(&mut self) {
        if self.mapped {
            self.layer
                .wl_surface()
                .set_input_region(Some(self.empty_input_region.wl_region()));
            self.layer.wl_surface().attach(None, 0, 0);
            self.layer.commit();
            self.buffers.clear();
            self.configured = false;
            self.configure_pending = false;
            self.mapped = false;
            self.frame_pending = false;
            self.request_full_redraw();
            incident::info("overlay.unmapped", "surface detached");
        }
    }

    fn acquire_surface_buffer(&mut self, width: u32, height: u32, stride: i32) -> Option<usize> {
        for index in 0..self.buffers.len() {
            if self.buffers[index].buffer.canvas(&mut self.pool).is_some() {
                return Some(index);
            }
        }
        if self.buffers.len() >= MAX_SURFACE_BUFFERS {
            return None;
        }

        let (buffer, _) = self
            .pool
            .create_buffer(
                width as i32,
                height as i32,
                stride,
                wl_shm::Format::Argb8888,
            )
            .expect("create overlay buffer");
        self.buffers.push(SurfaceBuffer {
            buffer,
            frame_key: None,
        });
        Some(self.buffers.len() - 1)
    }

    fn draw(&mut self, queue_handle: &QueueHandle<Self>) {
        let was_mapped = self.mapped;
        let requested_redraw = if was_mapped {
            self.redraw
        } else {
            Redraw::Full
        };
        let scale = self.scale.max(1) as u32;
        let width = self.width * scale;
        let height = self.height * scale;
        let stride = width as i32 * 4;
        let scene_visible =
            self.overlay_enabled && self.relic_scene.is_some() && self.warframe_active;
        let status_visible = self.overlay_enabled
            && self.hud_visible
            && self.warframe_active
            && (DEBUG_HUD || !scene_visible);
        let status = status_visible.then(|| {
            let origin = STATUS_INSET;
            let daemon = if DEBUG_HUD {
                format!("DEV | {}", self.daemon_summary())
            } else {
                self.daemon_summary()
            };
            let detail = if DEBUG_HUD {
                self.debug_summary()
            } else {
                "wfcli companion hud hide".to_owned()
            };
            (origin, daemon, self.player_summary(), detail)
        });
        let loading_elapsed = self
            .relic_scene
            .as_ref()
            .filter(|_| scene_visible)
            .map(|(_, _, started)| started.elapsed());
        if let Some((scene, _, _)) = self.relic_scene.as_ref().filter(|_| scene_visible) {
            let key = RelicFrameKey {
                width,
                height,
                scale,
                scene: scene.clone(),
                suggestion_offset: self.suggestion_offset,
                interaction_active: self.interaction_active,
                close_hovered: self.close_hovered,
            };
            if let Err(error) = ensure_relic_frame(
                &mut self.relic_frame_cache,
                key,
                &self.font,
                &self.platinum_icon,
                &self.ducat_icon,
                &self.suggestion_icons,
                &self.asset_images,
            ) {
                incident::error("overlay.render_failed", error);
                return;
            }
        }
        let Some(buffer_index) = self.acquire_surface_buffer(width, height, stride) else {
            return;
        };
        let buffer = &mut self.buffers[buffer_index];
        let canvas = buffer
            .buffer
            .canvas(&mut self.pool)
            .expect("selected overlay buffer is writable");

        let animation_bounds = if scene_visible {
            self.relic_frame_cache
                .as_ref()
                .and_then(|cache| cache.animation_bounds)
        } else {
            None
        };
        let partial_animation = scene_visible
            && requested_redraw == Redraw::Loading
            && animation_bounds.is_some()
            && buffer.frame_key.as_ref() == self.relic_frame_cache.as_ref().map(|cache| &cache.key);
        let damage = if scene_visible {
            let cache = self
                .relic_frame_cache
                .as_ref()
                .expect("visible relic scene has cached frame");
            if partial_animation {
                let bounds = animation_bounds.expect("loading scene has animation bounds");
                copy_frame_rect(&cache.pixels, canvas, width, bounds);
                bounds
            } else {
                canvas.copy_from_slice(&cache.pixels);
                buffer.frame_key = Some(cache.key.clone());
                Rect {
                    x: 0,
                    y: 0,
                    width,
                    height,
                }
            }
        } else {
            buffer.frame_key = None;
            Rect {
                x: 0,
                y: 0,
                width,
                height,
            }
        };

        let mut painter = match Painter::new(canvas, width, height) {
            Ok(painter) => painter,
            Err(error) => {
                incident::error("overlay.render_failed", error.to_string());
                return;
            }
        };
        if !scene_visible {
            painter.clear();
        }
        if let (Some(bounds), Some(elapsed)) = (animation_bounds, loading_elapsed) {
            draw_loading_pulse(&mut painter, bounds, scale, elapsed);
        }
        if !partial_animation && let Some((origin, daemon, player, detail)) = status.as_ref() {
            draw_status(
                &mut painter,
                &self.font,
                scale,
                *origin,
                *origin,
                daemon,
                player,
                detail,
            );
        }
        if let Err(error) = painter.finish() {
            incident::error("overlay.render_failed", error.to_string());
            return;
        }

        self.layer.wl_surface().damage_buffer(
            damage.x as i32,
            damage.y as i32,
            damage.width as i32,
            damage.height as i32,
        );
        if animation_bounds.is_some() && !self.frame_pending {
            self.layer
                .wl_surface()
                .frame(queue_handle, self.layer.wl_surface().clone());
            self.frame_pending = true;
        }
        self.layer
            .wl_surface()
            .set_input_region(Some(if self.interaction_active {
                self.interactive_input_region.wl_region()
            } else {
                self.empty_input_region.wl_region()
            }));
        buffer
            .buffer
            .attach_to(self.layer.wl_surface())
            .expect("attach overlay buffer");
        self.layer.commit();
        self.mapped = true;
        self.redraw = Redraw::None;
        if !was_mapped {
            incident::info(
                "overlay.mapped",
                format!(
                    "contextual={} size={}x{} scale={scale}",
                    self.contextual_surface, self.width, self.height
                ),
            );
        }
    }

    fn daemon_summary(&self) -> String {
        let version = self
            .snapshots
            .get("daemon")
            .and_then(|data| data.get("version"))
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let state = if self.connected {
            "connected"
        } else {
            "disconnected"
        };
        format!("wfdaemon {version} - {state}")
    }

    fn player_summary(&self) -> String {
        let game = self
            .snapshots
            .get("player")
            .and_then(|snapshot| snapshot.get("data"))
            .and_then(|data| data.get("game"));
        let phase = game
            .and_then(|data| data.get("phase"))
            .and_then(Value::as_str);
        let pid = game
            .and_then(|data| data.get("pid"))
            .and_then(Value::as_u64)
            .map(|pid| format!(" (pid {pid})"))
            .unwrap_or_default();
        match phase {
            Some("game") => format!("Warframe running{pid}"),
            Some("launcher") => format!("Warframe launcher running{pid}"),
            Some("stopped") => "Warframe stopped".to_owned(),
            _ => "Warframe state pending".to_owned(),
        }
    }

    fn debug_summary(&self) -> String {
        let collector = self
            .snapshots
            .get("player")
            .and_then(|snapshot| snapshot.get("data"))
            .and_then(|data| data.get("collector"));
        let bridge = collector
            .and_then(|data| data.get("debug_output_active"))
            .and_then(Value::as_bool)
            .map_or("?", |active| if active { "on" } else { "off" });
        let debug_lines = collector
            .and_then(|data| data.get("debug_output_lines_observed"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let log_lines = collector
            .and_then(|data| data.get("ee_log_lines_observed"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let scene = self
            .relic_scene
            .as_ref()
            .map_or("idle", |(scene, _, _)| scene_name(scene));
        format!("DBWIN {bridge} | dbg {debug_lines} | log {log_lines} | relic {scene}")
    }
}

fn scene_name(scene: &crate::relic::Scene) -> &'static str {
    match scene {
        crate::relic::Scene::Reading => "reading",
        crate::relic::Scene::Rewards(_) => "rewards",
        crate::relic::Scene::Suggestions(_) => "suggestions",
        crate::relic::Scene::Error(_) => "error",
    }
}

fn contextual_surface_required(
    overlay_enabled: bool,
    scene_visible: bool,
    status_visible: bool,
    currently_contextual: bool,
) -> bool {
    overlay_enabled && (scene_visible || (currently_contextual && !status_visible))
}

fn scene_deadline_is_current(deadline: Option<Instant>, now: Instant) -> bool {
    deadline.is_none_or(|deadline| deadline > now)
}

fn needs_remap_configure(should_draw: bool, configure_pending: bool) -> bool {
    should_draw && !configure_pending
}

fn max_suggestion_offset(item_count: usize) -> usize {
    item_count.saturating_sub(3) / 2 * 2
}

fn apply_layer_state(layer: &LayerSurface, contextual: bool) {
    layer.set_layer(Layer::Overlay);
    layer.set_anchor(if contextual {
        Anchor::TOP | Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT
    } else {
        Anchor::TOP | Anchor::LEFT
    });
    layer.set_keyboard_interactivity(KeyboardInteractivity::None);
    layer.set_exclusive_zone(if contextual { -1 } else { 0 });
    layer.set_margin(0, 0, 0, 0);
    layer.set_size(
        if contextual { 0 } else { STATUS_SURFACE_WIDTH },
        if contextual { 0 } else { STATUS_SURFACE_HEIGHT },
    );
}

impl CompositorHandler for Overlay {
    fn scale_factor_changed(
        &mut self,
        _connection: &Connection,
        _queue_handle: &QueueHandle<Self>,
        surface: &wl_surface::WlSurface,
        scale: i32,
    ) {
        if self.layer.wl_surface() == surface && self.scale != scale {
            self.scale = scale.max(1);
            self.layer.wl_surface().set_buffer_scale(self.scale);
            self.buffers.clear();
            self.request_full_redraw();
        }
    }

    fn transform_changed(
        &mut self,
        _connection: &Connection,
        _queue_handle: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _transform: wl_output::Transform,
    ) {
    }

    fn frame(
        &mut self,
        _connection: &Connection,
        _queue_handle: &QueueHandle<Self>,
        surface: &wl_surface::WlSurface,
        _time: u32,
    ) {
        if self.layer.wl_surface() == surface {
            self.frame_pending = false;
        }
    }

    fn surface_enter(
        &mut self,
        _connection: &Connection,
        _queue_handle: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _output: &wl_output::WlOutput,
    ) {
    }

    fn surface_leave(
        &mut self,
        _connection: &Connection,
        _queue_handle: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _output: &wl_output::WlOutput,
    ) {
    }
}

impl LayerShellHandler for Overlay {
    fn closed(
        &mut self,
        _connection: &Connection,
        _queue_handle: &QueueHandle<Self>,
        _layer: &LayerSurface,
    ) {
        incident::warn("overlay.closed", "compositor closed layer surface");
        self.stopping.store(true, Ordering::Relaxed);
        self.loop_signal.stop();
    }

    fn configure(
        &mut self,
        _connection: &Connection,
        _queue_handle: &QueueHandle<Self>,
        _layer: &LayerSurface,
        configure: LayerSurfaceConfigure,
        _serial: u32,
    ) {
        self.width = if configure.new_size.0 == 0 {
            if self.contextual_surface {
                self.width
            } else {
                STATUS_SURFACE_WIDTH
            }
        } else {
            configure.new_size.0
        };
        self.height = if configure.new_size.1 == 0 {
            if self.contextual_surface {
                self.height
            } else {
                STATUS_SURFACE_HEIGHT
            }
        } else {
            configure.new_size.1
        };
        self.buffers.clear();
        self.configured = true;
        self.configure_pending = false;
        self.request_full_redraw();
    }
}

impl OutputHandler for Overlay {
    fn output_state(&mut self) -> &mut OutputState {
        &mut self.output_state
    }

    fn new_output(
        &mut self,
        _connection: &Connection,
        _queue_handle: &QueueHandle<Self>,
        _output: wl_output::WlOutput,
    ) {
    }

    fn update_output(
        &mut self,
        _connection: &Connection,
        _queue_handle: &QueueHandle<Self>,
        _output: wl_output::WlOutput,
    ) {
    }

    fn output_destroyed(
        &mut self,
        _connection: &Connection,
        _queue_handle: &QueueHandle<Self>,
        _output: wl_output::WlOutput,
    ) {
    }
}

impl SeatHandler for Overlay {
    fn seat_state(&mut self) -> &mut SeatState {
        &mut self.seat_state
    }

    fn new_seat(
        &mut self,
        _connection: &Connection,
        _queue_handle: &QueueHandle<Self>,
        _seat: wl_seat::WlSeat,
    ) {
    }

    fn new_capability(
        &mut self,
        _connection: &Connection,
        queue_handle: &QueueHandle<Self>,
        seat: wl_seat::WlSeat,
        capability: Capability,
    ) {
        if capability == Capability::Pointer && self.themed_pointer.is_none() {
            let surface = self.compositor.create_surface(queue_handle);
            match self.seat_state.get_pointer_with_theme(
                queue_handle,
                &seat,
                self.shm.wl_shm(),
                surface,
                ThemeSpec::default(),
            ) {
                Ok(pointer) => self.themed_pointer = Some(pointer),
                Err(error) => incident::warn("overlay.pointer_failed", error.to_string()),
            }
        }
    }

    fn remove_capability(
        &mut self,
        _connection: &Connection,
        _queue_handle: &QueueHandle<Self>,
        _seat: wl_seat::WlSeat,
        capability: Capability,
    ) {
        if capability == Capability::Pointer
            && let Some(pointer) = self.themed_pointer.take()
        {
            pointer.pointer().release();
        }
    }

    fn remove_seat(
        &mut self,
        _connection: &Connection,
        _queue_handle: &QueueHandle<Self>,
        _seat: wl_seat::WlSeat,
    ) {
    }
}

impl PointerHandler for Overlay {
    fn pointer_frame(
        &mut self,
        connection: &Connection,
        _queue_handle: &QueueHandle<Self>,
        _pointer: &wl_pointer::WlPointer,
        events: &[PointerEvent],
    ) {
        for event in events {
            if &event.surface != self.layer.wl_surface() || !self.interaction_active {
                continue;
            }
            match event.kind {
                PointerEventKind::Enter { .. } | PointerEventKind::Motion { .. } => {
                    self.update_pointer(connection, event.position);
                }
                PointerEventKind::Leave { .. } => {
                    if self.close_hovered {
                        self.close_hovered = false;
                        self.request_full_redraw();
                    }
                    incident::info("overlay.pointer", "left_surface");
                    self.set_interaction(false);
                }
                PointerEventKind::Press { button, .. } if button == BTN_LEFT => {
                    self.update_pointer(connection, event.position);
                    let Some(layout) = self.suggestion_layout() else {
                        self.set_interaction(false);
                        continue;
                    };
                    if layout.close.contains(event.position.0, event.position.1) {
                        self.dismiss_suggestions();
                    } else if !layout.shell.contains(event.position.0, event.position.1) {
                        self.set_interaction(false);
                    }
                }
                PointerEventKind::Axis { vertical, .. } => {
                    self.update_pointer(connection, event.position);
                    let over_grid = self.suggestion_layout().is_some_and(|layout| {
                        layout.grid.contains(event.position.0, event.position.1)
                    });
                    if over_grid {
                        let delta = if vertical.value120 != 0 {
                            f64::from(vertical.value120) / 120.0
                        } else if vertical.discrete != 0 {
                            f64::from(vertical.discrete)
                        } else {
                            vertical.absolute / 15.0
                        };
                        self.scroll_suggestions(delta);
                    }
                }
                _ => {}
            }
        }
    }
}

impl ShmHandler for Overlay {
    fn shm_state(&mut self) -> &mut Shm {
        &mut self.shm
    }
}

impl ProvidesRegistryState for Overlay {
    fn registry(&mut self) -> &mut RegistryState {
        &mut self.registry_state
    }

    registry_handlers![OutputState, SeatState];
}

delegate_compositor!(Overlay);
delegate_output!(Overlay);
delegate_pointer!(Overlay);
delegate_seat!(Overlay);
delegate_shm!(Overlay);
delegate_layer!(Overlay);
delegate_registry!(Overlay);

#[allow(clippy::too_many_arguments)]
fn draw_status(
    painter: &mut Painter<'_>,
    font: &Font,
    scale: u32,
    x: u32,
    y: u32,
    daemon: &str,
    player: &str,
    detail: &str,
) {
    let x = x * scale;
    let y = y * scale;
    painter.fill_rounded_rect(
        x,
        y,
        WIDTH * scale,
        HEIGHT * scale,
        5 * scale,
        [18, 14, 12, 232],
    );
    painter.draw_text(
        font,
        x + 10 * scale,
        y + 8 * scale,
        13.0 * scale as f32,
        daemon,
        [255, 255, 255, 255],
    );
    painter.draw_text(
        font,
        x + 10 * scale,
        y + 32 * scale,
        16.0 * scale as f32,
        player,
        [255, 215, 180, 255],
    );
    painter.draw_text(
        font,
        x + 10 * scale,
        y + 64 * scale,
        11.0 * scale as f32,
        detail,
        [175, 175, 175, 255],
    );
}

fn ensure_relic_frame(
    cache: &mut Option<RelicFrameCache>,
    key: RelicFrameKey,
    font: &Font,
    platinum_icon: &RasterImage,
    ducat_icon: &RasterImage,
    suggestion_icons: &SuggestionIcons,
    asset_images: &BTreeMap<String, RasterImage>,
) -> Result<bool, String> {
    if cache.as_ref().is_some_and(|cached| cached.key == key) {
        return Ok(false);
    }

    let length = key
        .width
        .checked_mul(key.height)
        .and_then(|pixels| pixels.checked_mul(4))
        .and_then(|bytes| usize::try_from(bytes).ok())
        .ok_or_else(|| "relic frame dimensions overflow".to_owned())?;
    let mut pixels = vec![0; length];
    let mut painter = Painter::new(&mut pixels, key.width, key.height)
        .map_err(|error| format!("could not create relic frame painter: {error}"))?;
    painter.clear();
    let animation_bounds = draw_static_relic_scene(
        &mut painter,
        font,
        platinum_icon,
        ducat_icon,
        suggestion_icons,
        asset_images,
        key.scale,
        &key.scene,
        key.suggestion_offset,
        key.interaction_active,
        key.close_hovered,
    );
    painter
        .finish()
        .map_err(|error| format!("could not render relic frame: {error}"))?;
    *cache = Some(RelicFrameCache {
        key,
        pixels,
        animation_bounds,
    });
    Ok(true)
}

fn draw_relic_scene(
    painter: &mut Painter<'_>,
    font: &Font,
    platinum_icon: &RasterImage,
    ducat_icon: &RasterImage,
    suggestion_icons: &SuggestionIcons,
    asset_images: &BTreeMap<String, RasterImage>,
    scale: u32,
    scene: &crate::relic::Scene,
    elapsed: Duration,
    suggestion_offset: usize,
    interaction_active: bool,
    close_hovered: bool,
) {
    if let Some(bounds) = draw_static_relic_scene(
        painter,
        font,
        platinum_icon,
        ducat_icon,
        suggestion_icons,
        asset_images,
        scale,
        scene,
        suggestion_offset,
        interaction_active,
        close_hovered,
    ) {
        draw_loading_pulse(painter, bounds, scale, elapsed);
    }
}

fn draw_static_relic_scene(
    painter: &mut Painter<'_>,
    font: &Font,
    platinum_icon: &RasterImage,
    ducat_icon: &RasterImage,
    suggestion_icons: &SuggestionIcons,
    asset_images: &BTreeMap<String, RasterImage>,
    scale: u32,
    scene: &crate::relic::Scene,
    suggestion_offset: usize,
    interaction_active: bool,
    close_hovered: bool,
) -> Option<Rect> {
    if let crate::relic::Scene::Suggestions(suggestions) = scene {
        draw_relic_suggestions(
            painter,
            font,
            platinum_icon,
            ducat_icon,
            suggestion_icons,
            scale,
            suggestions,
            suggestion_offset,
            interaction_active,
            close_hovered,
        );
        return None;
    }
    let card_specs = match scene {
        crate::relic::Scene::Rewards(rewards) => rewards
            .items
            .iter()
            .take(4)
            .map(|reward| {
                let platinum = reward
                    .lowest_sell
                    .map_or_else(|| "--".to_owned(), |value| value.to_string());
                let ducats = reward
                    .ducats
                    .map_or_else(|| "--".to_owned(), |value| value.to_string());
                RelicCardSpec {
                    platinum_width: text_width(font, &platinum, 19.0).ceil() + 31.0,
                    ducats_width: text_width(font, &ducats, 19.0).ceil() + 33.0,
                    vaulted: reward.vaulted,
                    ..RelicCardSpec::default()
                }
            })
            .collect(),
        crate::relic::Scene::Suggestions(_) => unreachable!(),
        _ => vec![RelicCardSpec::default(); 4],
    };
    let layout = relic_layout(
        painter.width() / scale,
        painter.height() / scale,
        &card_specs,
    )
    .expect("static relic layout must be valid")
    .scaled(scale);
    let card_bounds = layout.cards;
    draw_relic_shell(painter, &layout, scale);
    match scene {
        crate::relic::Scene::Reading => {
            draw_loading_background(painter, layout.holder);
            return Some(loading_pulse_bounds(layout.holder, scale));
        }
        crate::relic::Scene::Error(error) => {
            draw_message_panel(
                painter,
                font,
                card_bounds,
                600 * scale,
                "Relic reward scan failed",
                Some(&truncate(error, 72)),
                scale,
            );
        }
        crate::relic::Scene::Rewards(rewards) => {
            let best = rewards
                .items
                .iter()
                .filter_map(|reward| reward.lowest_sell)
                .max();
            for (reward, card_layout) in rewards.items.iter().take(4).zip(&layout.reward_cards) {
                let card = card_layout.card;
                let selected = reward.lowest_sell.is_some() && reward.lowest_sell == best;
                if selected {
                    painter.fill_rounded_rect(
                        card.x,
                        card.y,
                        card.width,
                        card.height,
                        15 * scale,
                        css_rgba(212, 225, 255, 199),
                    );
                }
                let inset = if selected { 2 * scale } else { 0 };
                painter.fill_rounded_rect(
                    card.x + inset,
                    card.y + inset,
                    card.width - inset * 2,
                    card.height - inset * 2,
                    15 * scale,
                    if selected {
                        css_rgba(49, 58, 88, 255)
                    } else {
                        css_rgba(32, 40, 62, 255)
                    },
                );
                let name_size = fit_text_size(
                    font,
                    &reward.name,
                    18.0 * scale as f32,
                    12.0 * scale as f32,
                    card_layout.name.width.saturating_sub(8 * scale),
                );
                painter.draw_centered_text(
                    font,
                    TextBox::new(
                        card_layout.name.x,
                        card_layout.name.y,
                        card_layout.name.width,
                    ),
                    name_size,
                    &reward.name,
                    [255, 255, 255, 255],
                );
                if reward.slug.is_none() && reward.lowest_sell.is_none() && reward.ducats.is_none()
                {
                    painter.draw_centered_text(
                        font,
                        TextBox::new(
                            card_layout.prices.x,
                            card_layout.prices.y + 4 * scale,
                            card_layout.prices.width,
                        ),
                        14.0 * scale as f32,
                        "No market listing",
                        [165, 165, 165, 255],
                    );
                } else {
                    draw_primary_price(
                        painter,
                        font,
                        platinum_icon,
                        card_layout.platinum,
                        scale,
                        28,
                        reward.lowest_sell,
                        css_rgba(255, 255, 255, 255),
                    );
                    if let Some(bounds) = card_layout.vaulted {
                        painter.fill_rounded_rect(
                            bounds.x,
                            bounds.y,
                            bounds.width,
                            bounds.height,
                            12 * scale,
                            css_rgba(73, 79, 117, 255),
                        );
                        painter.draw_image_contained(
                            &suggestion_icons.vaulted,
                            bounds.x + 7 * scale,
                            bounds.y + 4 * scale,
                            22 * scale,
                            22 * scale,
                        );
                    }
                    draw_primary_price(
                        painter,
                        font,
                        ducat_icon,
                        card_layout.ducats,
                        scale,
                        30,
                        reward.ducats,
                        css_rgba(255, 255, 255, 255),
                    );
                }
                draw_reward_ownership(painter, font, reward, card_layout.ownership, scale);
                draw_reward_parts(
                    painter,
                    font,
                    platinum_icon,
                    asset_images,
                    reward,
                    card_layout.components,
                    scale,
                );
            }
            draw_account_currency(
                painter,
                font,
                platinum_icon,
                ducat_icon,
                layout.footer,
                scale,
                &rewards.account,
                interaction_active,
            );
        }
        crate::relic::Scene::Suggestions(_) => unreachable!(),
    }
    None
}

fn draw_relic_suggestions(
    painter: &mut Painter<'_>,
    font: &Font,
    platinum_icon: &RasterImage,
    ducat_icon: &RasterImage,
    icons: &SuggestionIcons,
    scale: u32,
    suggestions: &crate::relic::Suggestions,
    suggestion_offset: usize,
    interaction_active: bool,
    close_hovered: bool,
) {
    let layout = relic_suggestion_layout(
        painter.width() / scale,
        painter.height() / scale,
        suggestions.items.len(),
    )
    .scaled(scale);
    let shell = layout.shell;
    painter.fill_rounded_rect(
        shell.x,
        shell.y,
        shell.width,
        shell.height,
        20 * scale,
        css_rgba(255, 255, 255, 158),
    );
    let inner = shell.inset(2 * scale);
    painter.fill_rounded_rect(
        inner.x,
        inner.y,
        inner.width,
        inner.height,
        18 * scale,
        css_rgba(23, 30, 48, 255),
    );
    painter.fill_rounded_rect(
        layout.header.x,
        layout.header.y,
        layout.header.width,
        layout.header.height,
        18 * scale,
        css_rgba(32, 40, 62, 255),
    );
    painter.fill_rounded_rect(
        layout.header.x,
        layout.header.y + 18 * scale,
        layout.header.width,
        layout.header.height.saturating_sub(18 * scale),
        0,
        css_rgba(32, 40, 62, 255),
    );
    painter.draw_centered_text(
        font,
        TextBox::new(
            layout.header.x,
            layout.header.y + 8 * scale,
            layout.header.width,
        ),
        21.0 * scale as f32,
        "Recommended relics",
        [255, 255, 255, 255],
    );
    painter.draw_image_contained(
        &icons.trace,
        layout.header.x + 14 * scale,
        layout.header.y + 10 * scale,
        24 * scale,
        24 * scale,
    );
    painter.draw_text_vertically_centered(
        font,
        layout.header.x + 41 * scale,
        layout.header.y,
        layout.header.height,
        16.0 * scale as f32,
        &suggestions.trace_count.to_string(),
        [255, 255, 255, 255],
    );
    if close_hovered {
        painter.fill_rounded_rect(
            layout.close.x,
            layout.close.y,
            layout.close.width,
            layout.close.height,
            6 * scale,
            css_rgba(139, 171, 204, 107),
        );
    }
    painter.draw_image_contained(
        &icons.close,
        layout.close.x + 5 * scale,
        layout.close.y + 5 * scale,
        18 * scale,
        18 * scale,
    );

    let grid = layout.grid;
    painter.fill_rounded_rect(
        grid.x,
        grid.y,
        grid.width,
        grid.height,
        0,
        css_rgba(16, 22, 35, 255),
    );

    for (suggestion, card) in suggestions
        .items
        .iter()
        .skip(suggestion_offset)
        .take(4)
        .zip(layout.cards)
    {
        if suggestion.favorite {
            painter.fill_rounded_rect(
                card.x,
                card.y,
                card.width,
                card.height,
                15 * scale,
                css_rgba(252, 255, 69, 214),
            );
        }
        let outline = if suggestion.favorite { 2 * scale } else { 0 };
        painter.fill_rounded_rect(
            card.x + outline,
            card.y + outline,
            card.width.saturating_sub(outline * 2),
            card.height.saturating_sub(outline * 2),
            15 * scale,
            css_rgba(32, 40, 62, 255),
        );
        let count = format!("{}x", suggestion.amount_owned);
        let count_width = text_width(font, &count, 17.0 * scale as f32).ceil() as u32;
        let title_size = fit_text_size(
            font,
            &suggestion.name,
            19.0 * scale as f32,
            13.0 * scale as f32,
            card.width.saturating_sub(70 * scale),
        );
        let title_width = text_width(font, &suggestion.name, title_size).ceil() as u32;
        let vaulted_width = if suggestion.vaulted { 25 * scale } else { 0 };
        let gaps = if suggestion.vaulted {
            16 * scale
        } else {
            8 * scale
        };
        let top_width = vaulted_width + count_width + title_width + gaps;
        let mut top_x = card.x + card.width.saturating_sub(top_width) / 2;
        let top_y = card.y + 6 * scale;
        if suggestion.vaulted {
            painter.draw_image_contained(&icons.vaulted, top_x, top_y, 25 * scale, 24 * scale);
            top_x += 33 * scale;
        }
        painter.draw_text_vertically_centered(
            font,
            top_x,
            top_y,
            24 * scale,
            17.0 * scale as f32,
            &count,
            [255, 255, 255, 255],
        );
        top_x += count_width + 8 * scale;
        painter.draw_text_vertically_centered(
            font,
            top_x,
            top_y,
            24 * scale,
            title_size,
            &suggestion.name,
            [255, 255, 255, 255],
        );

        let price_size = 17.0 * scale as f32;
        let label_width = text_width(font, "E. profits:", price_size).ceil() as u32;
        let platinum = suggestion
            .expected_platinum
            .map_or_else(|| "--".to_owned(), |value| value.to_string());
        let ducats = suggestion.expected_ducats.to_string();
        let platinum_width = text_width(font, &platinum, price_size).ceil() as u32 + 23 * scale;
        let ducat_width = text_width(font, &ducats, price_size).ceil() as u32 + 23 * scale;
        let row_width = label_width + 10 * scale + platinum_width + 14 * scale + ducat_width;
        let row_x = card.x + card.width.saturating_sub(row_width) / 2;
        let row_y = card.y + card.height.saturating_sub(27 * scale);
        painter.draw_text_vertically_centered(
            font,
            row_x,
            row_y,
            20 * scale,
            price_size,
            "E. profits:",
            [255, 255, 255, 255],
        );
        draw_suggestion_price(
            painter,
            font,
            platinum_icon,
            row_x + label_width + 10 * scale,
            row_y,
            scale,
            &platinum,
        );
        draw_suggestion_price(
            painter,
            font,
            ducat_icon,
            row_x + label_width + 10 * scale + platinum_width + 14 * scale,
            row_y,
            scale,
            &ducats,
        );
    }
    if suggestions.items.is_empty() {
        painter.draw_centered_text(
            font,
            TextBox::new(grid.x, grid.y + grid.height / 2 - 8 * scale, grid.width),
            16.0 * scale as f32,
            "No owned relics found for this era",
            [255, 255, 255, 255],
        );
    }
    painter.draw_centered_text(
        font,
        TextBox::new(
            layout.footer.x + 8 * scale,
            layout.footer.y + 6 * scale,
            layout.footer.width.saturating_sub(16 * scale),
        ),
        16.0 * scale as f32,
        if interaction_active {
            "Press Ctrl + Tab or click outside to return to the game"
        } else {
            "Press Ctrl + Tab to interact with the overlay"
        },
        [255, 255, 255, 255],
    );
}

fn draw_suggestion_price(
    painter: &mut Painter<'_>,
    font: &Font,
    icon: &RasterImage,
    x: u32,
    y: u32,
    scale: u32,
    value: &str,
) {
    let size = 17.0 * scale as f32;
    let value_width = text_width(font, value, size).ceil() as u32;
    painter.draw_text_vertically_centered(
        font,
        x,
        y,
        20 * scale,
        size,
        value,
        [255, 255, 255, 255],
    );
    painter.draw_image_contained(icon, x + value_width + 3 * scale, y, 20 * scale, 20 * scale);
}

fn draw_loading_background(painter: &mut Painter<'_>, bounds: Rect) {
    painter.fill_rounded_rect(
        bounds.x,
        bounds.y,
        bounds.width,
        bounds.height,
        0,
        css_rgba(28, 31, 32, 56),
    );
}

fn loading_pulse_bounds(bounds: Rect, scale: u32) -> Rect {
    let radius = (LOADING_RADIUS + LOADING_STROKE.div_ceil(2) + 1) * scale;
    let center_x = bounds.x + bounds.width / 2;
    let center_y = bounds.y + bounds.height / 2;
    Rect {
        x: center_x.saturating_sub(radius),
        y: center_y.saturating_sub(radius),
        width: (radius * 2).min(bounds.width),
        height: (radius * 2).min(bounds.height),
    }
}

fn draw_loading_pulse(painter: &mut Painter<'_>, bounds: Rect, scale: u32, elapsed: Duration) {
    let center_x = bounds.x + bounds.width / 2;
    let center_y = bounds.y + bounds.height / 2;
    let cycle = elapsed.as_secs_f32() / LOADING_CYCLE;
    for (offset, color) in [(0.0, (147, 219, 233)), (0.5, (104, 156, 197))] {
        let phase = (cycle + offset) % 1.0;
        let radius = (phase * LOADING_RADIUS as f32 * scale as f32).round() as u32;
        let alpha = ((1.0 - phase) * 255.0).round() as u8;
        painter.draw_ring(
            center_x,
            center_y,
            radius,
            LOADING_STROKE * scale,
            css_rgba(color.0, color.1, color.2, alpha),
        );
    }
}

fn draw_relic_shell(painter: &mut Painter<'_>, layout: &RelicLayout, scale: u32) {
    let bounds = layout.shell;
    painter.fill_rounded_rect(
        bounds.x,
        bounds.y,
        bounds.width,
        bounds.height,
        20 * scale,
        css_rgba(255, 255, 255, 51),
    );
    let inner = bounds.inset(2 * scale);
    painter.fill_rounded_rect(
        inner.x,
        inner.y,
        inner.width,
        inner.height,
        18 * scale,
        css_rgba(16, 22, 35, 255),
    );
    fill_bottom_left_rounded(
        painter,
        layout.footer,
        18 * scale,
        css_rgba(23, 30, 48, 255),
    );
    fill_right_rounded(
        painter,
        layout.sidebar,
        18 * scale,
        css_rgba(15, 19, 28, 255),
    );
    painter.fill_rounded_rect(
        layout.sidebar.x,
        layout.sidebar.y,
        scale,
        layout.sidebar.height,
        0,
        css_rgba(255, 255, 255, 150),
    );
}

fn fill_bottom_left_rounded(painter: &mut Painter<'_>, bounds: Rect, radius: u32, color: [u8; 4]) {
    debug_assert_eq!(color[3], 255, "overlapping fills require an opaque color");
    let radius = radius.min(bounds.width / 2).min(bounds.height / 2);
    painter.fill_rounded_rect(
        bounds.x,
        bounds.y,
        bounds.width,
        bounds.height,
        radius,
        color,
    );
    painter.fill_rounded_rect(
        bounds.x,
        bounds.y,
        bounds.width,
        bounds.height.saturating_sub(radius),
        0,
        color,
    );
    painter.fill_rounded_rect(
        bounds.x + bounds.width.saturating_sub(radius),
        bounds.y,
        radius,
        bounds.height,
        0,
        color,
    );
}

fn fill_right_rounded(painter: &mut Painter<'_>, bounds: Rect, radius: u32, color: [u8; 4]) {
    debug_assert_eq!(color[3], 255, "overlapping fills require an opaque color");
    let radius = radius.min(bounds.width / 2).min(bounds.height / 2);
    painter.fill_rounded_rect(
        bounds.x,
        bounds.y,
        bounds.width,
        bounds.height,
        radius,
        color,
    );
    painter.fill_rounded_rect(bounds.x, bounds.y, radius, bounds.height, 0, color);
}

fn fill_left_rounded(painter: &mut Painter<'_>, bounds: Rect, radius: u32, color: [u8; 4]) {
    debug_assert_eq!(color[3], 255, "overlapping fills require an opaque color");
    let radius = radius.min(bounds.width / 2).min(bounds.height / 2);
    painter.fill_rounded_rect(
        bounds.x,
        bounds.y,
        bounds.width,
        bounds.height,
        radius,
        color,
    );
    painter.fill_rounded_rect(
        bounds.x + bounds.width.saturating_sub(radius),
        bounds.y,
        radius,
        bounds.height,
        0,
        color,
    );
}

fn mock_relic_scene() -> crate::relic::Scene {
    crate::relic::Scene::Rewards(crate::relic::Rewards {
        items: vec![
            crate::relic::Reward {
                name: "Lex Prime Barrel".to_owned(),
                slug: Some("lex_prime_barrel".to_owned()),
                game_ref: None,
                ducats: Some(15),
                lowest_sell: Some(15),
                highest_buy: Some(11),
                count_owned: 2,
                total_to_own: 2,
                crafted: Some(false),
                set_complete: Some(false),
                vaulted: true,
                set_price: Some(78),
                asset: None,
                parts: mock_parts(
                    &[("Blueprint", 1, 1), ("Barrel", 2, 2), ("Receiver", 0, 1)],
                    1,
                ),
            },
            crate::relic::Reward {
                name: "Gara Prime Systems Blueprint".to_owned(),
                slug: Some("gara_prime_systems_blueprint".to_owned()),
                game_ref: None,
                ducats: Some(100),
                lowest_sell: Some(8),
                highest_buy: Some(6),
                count_owned: 1,
                total_to_own: 1,
                crafted: Some(true),
                set_complete: Some(true),
                vaulted: false,
                set_price: Some(42),
                asset: None,
                parts: mock_parts(
                    &[
                        ("Blueprint", 1, 1),
                        ("Chassis", 1, 1),
                        ("Neuroptics", 1, 1),
                        ("Systems", 1, 1),
                    ],
                    3,
                ),
            },
            crate::relic::Reward {
                name: "Inaros Prime Systems Blueprint".to_owned(),
                slug: Some("inaros_prime_systems_blueprint".to_owned()),
                game_ref: None,
                ducats: Some(100),
                lowest_sell: Some(12),
                highest_buy: Some(9),
                count_owned: 0,
                total_to_own: 1,
                crafted: Some(false),
                set_complete: Some(false),
                vaulted: true,
                set_price: Some(51),
                asset: None,
                parts: mock_parts(
                    &[
                        ("Blueprint", 1, 1),
                        ("Chassis", 0, 1),
                        ("Neuroptics", 2, 1),
                        ("Systems", 0, 1),
                    ],
                    3,
                ),
            },
            crate::relic::Reward {
                name: "Forma Blueprint".to_owned(),
                slug: None,
                game_ref: Some("/Lotus/Types/Recipes/Components/FormaBlueprint".to_owned()),
                ducats: Some(0),
                lowest_sell: Some(2),
                highest_buy: None,
                count_owned: 4,
                total_to_own: 1,
                crafted: Some(true),
                set_complete: None,
                vaulted: false,
                set_price: None,
                asset: None,
                parts: Vec::new(),
            },
        ],
        account: crate::relic::Account {
            platinum: Some(124),
            ducats: Some(915),
        },
    })
}

fn mock_parts(parts: &[(&str, u64, u64)], current: usize) -> Vec<crate::relic::SetPart> {
    parts
        .iter()
        .enumerate()
        .map(|(index, (name, owned, required))| crate::relic::SetPart {
            name: (*name).to_owned(),
            owned: *owned,
            required: *required,
            current: index == current,
            asset: mock_part_asset(name),
        })
        .collect()
}

fn mock_part_asset(name: &str) -> Option<crate::relic::Asset> {
    let id = match name {
        "Blueprint" => "sub_icons/blueprint_128x128.png",
        "Barrel" => "sub_icons/weapon/prime_barrel_128x128.png",
        "Receiver" => "sub_icons/weapon/prime_receiver_128x128.png",
        "Chassis" => "sub_icons/warframe/prime_chassis_128x128.png",
        "Neuroptics" => "sub_icons/warframe/prime_helmet_128x128.png",
        "Systems" => "sub_icons/warframe/prime_systems_128x128.png",
        _ => return None,
    };
    let embedded = crate::assets::embedded_part("market", id)?;
    Some(crate::relic::Asset {
        id: format!("preview:{name}"),
        path: String::new(),
        digest: embedded.image.key.to_owned(),
    })
}

fn draw_message_panel(
    painter: &mut Painter<'_>,
    font: &Font,
    bounds: Rect,
    preferred_width: u32,
    title: &str,
    detail: Option<&str>,
    scale: u32,
) {
    let panel_width = preferred_width.min(bounds.width);
    let panel_height = 92 * scale;
    let x = bounds.x + (bounds.width - panel_width) / 2;
    painter.fill_rounded_rect(
        x,
        bounds.y,
        panel_width,
        panel_height,
        7 * scale,
        if detail.is_some() {
            css_rgba(18, 18, 28, 238)
        } else {
            css_rgba(12, 14, 18, 238)
        },
    );
    painter.draw_centered_text(
        font,
        TextBox::new(
            x,
            bounds.y + (if detail.is_some() { 16 } else { 25 }) * scale,
            panel_width,
        ),
        if detail.is_some() { 16.0 } else { 18.0 } * scale as f32,
        title,
        [255, 255, 255, 255],
    );
    if let Some(detail) = detail {
        painter.draw_centered_text(
            font,
            TextBox::new(x, bounds.y + 48 * scale, panel_width),
            13.0 * scale as f32,
            detail,
            [175, 175, 175, 255],
        );
    }
}

fn draw_primary_price(
    painter: &mut Painter<'_>,
    font: &Font,
    icon: &RasterImage,
    bounds: Rect,
    scale: u32,
    icon_size: u32,
    price: Option<u64>,
    color: [u8; 4],
) {
    let value = price.map_or_else(|| "--".to_owned(), |value| value.to_string());
    let size = 19.0 * scale as f32;
    let icon_size = icon_size * scale;
    painter.draw_text_vertically_centered(
        font,
        bounds.x,
        bounds.y,
        bounds.height,
        size,
        &value,
        color,
    );
    painter.draw_image_contained(
        icon,
        bounds.x + bounds.width.saturating_sub(icon_size),
        bounds.y + bounds.height.saturating_sub(icon_size) / 2,
        icon_size,
        icon_size,
    );
}

fn draw_reward_ownership(
    painter: &mut Painter<'_>,
    font: &Font,
    reward: &crate::relic::Reward,
    bounds: Rect,
    scale: u32,
) {
    let status = match reward.crafted {
        Some(true) => "Crafted",
        Some(false) => "Not crafted",
        None => "-",
    };
    let status_background = match reward.crafted {
        Some(true) => css_rgba(51, 82, 66, 255),
        Some(false) => css_rgba(83, 65, 117, 255),
        None => css_rgba(57, 62, 78, 255),
    };
    let status_width = bounds.width * 5 / 7;
    let count_width = bounds.width.saturating_sub(status_width);
    let radius = bounds.height / 2;
    fill_left_rounded(
        painter,
        Rect {
            x: bounds.x,
            y: bounds.y,
            width: status_width,
            height: bounds.height,
        },
        radius,
        status_background,
    );
    fill_right_rounded(
        painter,
        Rect {
            x: bounds.x + status_width,
            y: bounds.y,
            width: count_width,
            height: bounds.height,
        },
        radius,
        css_rgba(23, 29, 45, 255),
    );
    painter.draw_centered_text(
        font,
        TextBox::new(bounds.x, bounds.y + 4 * scale, status_width),
        16.0 * scale as f32,
        status,
        [255, 255, 255, 255],
    );
    let owned = format!("{}/{}", reward.count_owned, reward.total_to_own);
    painter.draw_centered_text(
        font,
        TextBox::new(bounds.x + status_width, bounds.y + 4 * scale, count_width),
        16.0 * scale as f32,
        &owned,
        [255, 255, 255, 255],
    );
}

fn draw_reward_parts(
    painter: &mut Painter<'_>,
    font: &Font,
    platinum_icon: &RasterImage,
    asset_images: &BTreeMap<String, RasterImage>,
    reward: &crate::relic::Reward,
    bounds: Rect,
    scale: u32,
) {
    let parts = reward.parts.iter().take(5).collect::<Vec<_>>();
    if parts.is_empty() {
        return;
    }
    let has_set_price = reward.set_price.is_some_and(|price| price > 0);
    let price_height = if has_set_price { 22 * scale } else { 0 };
    let connector_height = if has_set_price { 16 * scale } else { 0 };
    let tile_size = (42 * scale).min(
        bounds
            .height
            .saturating_sub(connector_height + price_height),
    );
    let gap = 4 * scale;
    let row_width = tile_size
        .saturating_mul(parts.len() as u32)
        .saturating_add(gap.saturating_mul(parts.len().saturating_sub(1) as u32));
    let mut x = bounds.x + bounds.width.saturating_sub(row_width) / 2;
    let group_height = tile_size + connector_height + price_height;
    let y = bounds.y + bounds.height.saturating_sub(group_height) / 2;

    for part in parts {
        let complete = part.owned >= part.required;
        let background = if complete {
            css_rgba(49, 99, 48, 181)
        } else {
            css_rgba(255, 255, 255, 38)
        };
        painter.fill_rounded_rect(x, y, tile_size, tile_size, tile_size / 2, background);
        if let Some(image) = part
            .asset
            .as_ref()
            .and_then(|asset| asset_images.get(&asset.digest))
        {
            painter.draw_image_contained_circle(
                image,
                x + 2 * scale,
                y + 2 * scale,
                tile_size.saturating_sub(4 * scale),
            );
        }
        if part.current {
            painter.draw_ring(
                x + tile_size / 2,
                y + tile_size / 2,
                tile_size.saturating_sub(2 * scale) / 2,
                2 * scale,
                css_rgba(220, 203, 0, 255),
            );
        }
        let count = part.owned.to_string();
        let count_width = text_width(font, &count, 16.0 * scale as f32).ceil() as u32;
        painter.fill_rounded_rect(
            x + tile_size.saturating_sub(count_width + 8 * scale),
            y + tile_size.saturating_sub(21 * scale),
            count_width + 8 * scale,
            21 * scale,
            5 * scale,
            css_rgba(0, 0, 0, 186),
        );
        painter.draw_text(
            font,
            x + tile_size.saturating_sub(count_width + 4 * scale),
            y + tile_size.saturating_sub(20 * scale),
            16.0 * scale as f32,
            &count,
            [255, 255, 255, 255],
        );
        x += tile_size + gap;
    }

    if let Some(set_price) = reward.set_price.filter(|price| *price > 0) {
        let line = css_rgba(255, 255, 255, 71);
        let bracket_top = y + tile_size + 3 * scale;
        painter.fill_rounded_rect(
            bounds.x + bounds.width.saturating_sub(row_width) / 2,
            bracket_top,
            2 * scale,
            8 * scale,
            0,
            line,
        );
        painter.fill_rounded_rect(
            bounds.x + (bounds.width + row_width).saturating_sub(2 * scale) / 2,
            bracket_top,
            2 * scale,
            8 * scale,
            0,
            line,
        );
        painter.fill_rounded_rect(
            bounds.x + bounds.width.saturating_sub(row_width) / 2,
            bracket_top + 6 * scale,
            row_width,
            2 * scale,
            0,
            line,
        );
        painter.fill_rounded_rect(
            bounds.x + bounds.width / 2,
            bracket_top + 8 * scale,
            2 * scale,
            4 * scale,
            0,
            line,
        );
        let label_size = 17.0 * scale as f32;
        let value = set_price.to_string();
        let value_width = text_width(font, &value, label_size).ceil() as u32;
        let icon_size = 22 * scale;
        let total_width = value_width + 3 * scale + icon_size;
        let price_x = bounds.x + bounds.width.saturating_sub(total_width) / 2;
        let price_y = y + tile_size + connector_height;
        painter.draw_text_vertically_centered(
            font,
            price_x,
            price_y,
            price_height,
            label_size,
            &value,
            [255, 255, 255, 255],
        );
        painter.draw_image_contained(
            platinum_icon,
            price_x + value_width + 3 * scale,
            price_y + price_height.saturating_sub(icon_size) / 2,
            icon_size,
            icon_size,
        );
    }
}

fn draw_account_currency(
    painter: &mut Painter<'_>,
    font: &Font,
    platinum_icon: &RasterImage,
    ducat_icon: &RasterImage,
    bounds: Rect,
    scale: u32,
    account: &crate::relic::Account,
    interaction_active: bool,
) {
    let brand = "wfcompanion";
    painter.draw_text_vertically_centered(
        font,
        bounds.x + 16 * scale,
        bounds.y,
        bounds.height,
        18.0 * scale as f32,
        brand,
        [255, 255, 255, 255],
    );
    let hint = if interaction_active {
        "Press Ctrl + Tab or click outside to return to the game"
    } else {
        "Press Ctrl + Tab to interact with the overlay"
    };
    let hint_width = text_width(font, hint, 18.0 * scale as f32).ceil() as u32 + 24 * scale;
    let hint_x = bounds.x + bounds.width.saturating_sub(hint_width) / 2;
    painter.fill_rounded_rect(
        hint_x,
        bounds.y + bounds.height.saturating_sub(27 * scale) / 2,
        hint_width,
        27 * scale,
        14 * scale,
        css_rgba(23, 30, 48, 255),
    );
    painter.draw_centered_text(
        font,
        TextBox::new(hint_x, bounds.y + 14 * scale, hint_width),
        18.0 * scale as f32,
        hint,
        [255, 255, 255, 255],
    );

    let platinum = account
        .platinum
        .map_or_else(|| "--".to_owned(), |value| value.to_string());
    let ducats = account
        .ducats
        .map_or_else(|| "--".to_owned(), |value| value.to_string());
    let platinum_width =
        text_width(font, &platinum, 18.0 * scale as f32).ceil() as u32 + 31 * scale;
    let ducat_width = text_width(font, &ducats, 18.0 * scale as f32).ceil() as u32 + 31 * scale;
    let right = bounds.x + bounds.width.saturating_sub(10 * scale);
    draw_primary_price(
        painter,
        font,
        platinum_icon,
        Rect {
            x: right.saturating_sub(ducat_width + 12 * scale + platinum_width),
            y: bounds.y,
            width: platinum_width,
            height: bounds.height,
        },
        scale,
        22,
        account.platinum,
        [255, 255, 255, 255],
    );
    draw_primary_price(
        painter,
        font,
        ducat_icon,
        Rect {
            x: right.saturating_sub(ducat_width),
            y: bounds.y,
            width: ducat_width,
            height: bounds.height,
        },
        scale,
        23,
        account.ducats,
        [255, 255, 255, 255],
    );
}

fn truncate(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_owned();
    }
    let mut value: String = text.chars().take(max_chars.saturating_sub(3)).collect();
    value.push_str("...");
    value
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_part_registry_matches_resolver() {
        let images = embedded_part_images().unwrap();
        assert_eq!(images.len(), 23);
        assert!(images.len() < crate::assets::EMBEDDED_PART_ASSETS.len());
        assert!(
            crate::assets::EMBEDDED_PART_ASSETS
                .iter()
                .all(|asset| images.contains_key(asset.image.key))
        );
        for name in [
            "Blueprint",
            "Barrel",
            "Receiver",
            "Chassis",
            "Neuroptics",
            "Systems",
        ] {
            let asset = mock_part_asset(name).unwrap();
            assert!(images.contains_key(&asset.digest));
        }
    }

    #[test]
    fn loading_layers_stay_inside_relic_holder() {
        let mut canvas = vec![0; 120 * 80 * 4];
        let bounds = Rect {
            x: 20,
            y: 10,
            width: 80,
            height: 60,
        };
        let mut painter = Painter::new(&mut canvas, 120, 80).unwrap();
        draw_loading_background(&mut painter, bounds);
        draw_loading_pulse(
            &mut painter,
            loading_pulse_bounds(bounds, 1),
            1,
            Duration::from_millis(750),
        );
        painter.finish().unwrap();

        assert_eq!(pixel(&canvas, 120, 19, 40), [0, 0, 0, 0]);
        assert!(pixel(&canvas, 120, 20, 40)[3] > 0);
        assert!(pixel(&canvas, 120, 60, 40)[3] > 0);
        assert_eq!(pixel(&canvas, 120, 100, 40), [0, 0, 0, 0]);
    }

    #[test]
    fn mock_scene_has_four_reward_cards() {
        let crate::relic::Scene::Rewards(rewards) = mock_relic_scene() else {
            panic!("mock scene must contain rewards");
        };
        assert_eq!(rewards.items.len(), 4);
        assert_eq!(rewards.items[1].ducats, Some(100));
    }

    #[test]
    fn suggestion_fixture_has_four_ranked_relics() {
        let crate::relic::Scene::Suggestions(suggestions) =
            crate::relic::suggestion_fixture().unwrap()
        else {
            panic!("fixture must contain suggestions");
        };
        assert_eq!(suggestions.items.len(), 4);
        assert!(
            suggestions.items[0].expected_platinum.unwrap()
                >= suggestions.items[1].expected_platinum.unwrap()
        );
    }

    #[test]
    fn static_relic_frame_is_reused_until_scene_changes() {
        let font = load_overlay_font().unwrap();
        let platinum_icon = load_icon(include_bytes!("../assets/platinum.png")).unwrap();
        let ducat_icon = load_icon(include_bytes!("../assets/ducats.png")).unwrap();
        let suggestion_icons = SuggestionIcons::load().unwrap();
        let key = RelicFrameKey {
            width: 2560,
            height: 1440,
            scale: 1,
            scene: mock_relic_scene(),
            suggestion_offset: 0,
            interaction_active: false,
            close_hovered: false,
        };
        let mut cache = None;
        let assets = BTreeMap::new();

        assert!(
            ensure_relic_frame(
                &mut cache,
                key.clone(),
                &font,
                &platinum_icon,
                &ducat_icon,
                &suggestion_icons,
                &assets,
            )
            .unwrap()
        );
        assert!(
            !ensure_relic_frame(
                &mut cache,
                key,
                &font,
                &platinum_icon,
                &ducat_icon,
                &suggestion_icons,
                &assets,
            )
            .unwrap()
        );
        assert!(cache.as_ref().unwrap().animation_bounds.is_none());

        let reading = RelicFrameKey {
            width: 2560,
            height: 1440,
            scale: 1,
            scene: crate::relic::Scene::Reading,
            suggestion_offset: 0,
            interaction_active: false,
            close_hovered: false,
        };
        assert!(
            ensure_relic_frame(
                &mut cache,
                reading,
                &font,
                &platinum_icon,
                &ducat_icon,
                &suggestion_icons,
                &assets,
            )
            .unwrap()
        );
        assert!(cache.as_ref().unwrap().animation_bounds.is_some());
    }

    #[test]
    fn frame_rect_copy_leaves_other_pixels_untouched() {
        let source = vec![7; 8 * 6 * 4];
        let mut target = vec![3; source.len()];
        copy_frame_rect(
            &source,
            &mut target,
            8,
            Rect {
                x: 2,
                y: 1,
                width: 3,
                height: 2,
            },
        );

        assert_eq!(&target[(1 * 8 + 2) * 4..(1 * 8 + 5) * 4], &[7; 12]);
        assert_eq!(&target[(2 * 8 + 2) * 4..(2 * 8 + 5) * 4], &[7; 12]);
        assert_eq!(target[0], 3);
        assert_eq!(target[(3 * 8 + 2) * 4], 3);
    }

    #[test]
    fn loading_damage_only_covers_the_pulse() {
        let holder = Rect {
            x: 20,
            y: 10,
            width: 800,
            height: 200,
        };

        assert_eq!(
            loading_pulse_bounds(holder, 1),
            Rect {
                x: 392,
                y: 82,
                width: 56,
                height: 56,
            }
        );
    }

    #[test]
    fn loading_pulse_never_writes_outside_its_damage() {
        let damage = Rect {
            x: 32,
            y: 12,
            width: 56,
            height: 56,
        };
        for elapsed in [0, 250, 750, 1_250, 1_900] {
            let mut canvas = vec![0; 120 * 80 * 4];
            let mut painter = Painter::new(&mut canvas, 120, 80).unwrap();
            draw_loading_pulse(&mut painter, damage, 1, Duration::from_millis(elapsed));
            painter.finish().unwrap();

            for y in 0..80 {
                for x in 0..120 {
                    let outside = x < damage.x
                        || x >= damage.x + damage.width
                        || y < damage.y
                        || y >= damage.y + damage.height;
                    if outside {
                        assert_eq!(pixel(&canvas, 120, x, y), [0; 4]);
                    }
                }
            }
        }
    }

    #[test]
    fn relic_sections_keep_only_outer_shell_corners_rounded() {
        let mut canvas = vec![0; 220 * 80 * 4];
        let color = css_rgba(23, 30, 48, 255);
        let mut painter = Painter::new(&mut canvas, 220, 80).unwrap();
        fill_bottom_left_rounded(
            &mut painter,
            Rect {
                x: 20,
                y: 20,
                width: 80,
                height: 40,
            },
            10,
            color,
        );
        fill_right_rounded(
            &mut painter,
            Rect {
                x: 120,
                y: 20,
                width: 80,
                height: 40,
            },
            10,
            color,
        );
        painter.finish().unwrap();

        assert!(pixel(&canvas, 220, 20, 59)[3] < 32);
        assert_eq!(pixel(&canvas, 220, 20, 20), color);
        assert_eq!(pixel(&canvas, 220, 99, 59), color);
        assert!(pixel(&canvas, 220, 199, 20)[3] < 32);
        assert_eq!(pixel(&canvas, 220, 120, 20), color);
        assert_eq!(pixel(&canvas, 220, 120, 59), color);
    }

    #[test]
    fn persistent_and_current_scene_updates_are_accepted() {
        let now = Instant::now();
        assert!(scene_deadline_is_current(None, now));
        assert!(scene_deadline_is_current(
            Some(now + Duration::from_secs(1)),
            now
        ));
        assert!(!scene_deadline_is_current(Some(now), now));
    }

    #[test]
    fn overlay_visibility_controls_contextual_surface() {
        assert!(contextual_surface_required(true, true, false, false));
        assert!(contextual_surface_required(true, false, false, true));
        assert!(!contextual_surface_required(true, false, true, true));
        assert!(!contextual_surface_required(true, false, false, false));
        assert!(!contextual_surface_required(false, true, false, true));
    }

    #[test]
    fn unmapped_surface_requests_one_configure_before_drawing() {
        assert!(needs_remap_configure(true, false));
        assert!(!needs_remap_configure(true, true));
        assert!(!needs_remap_configure(false, false));
    }

    #[test]
    fn suggestion_scroll_stays_on_complete_rows() {
        assert_eq!(max_suggestion_offset(0), 0);
        assert_eq!(max_suggestion_offset(4), 0);
        assert_eq!(max_suggestion_offset(5), 2);
        assert_eq!(max_suggestion_offset(6), 2);
        assert_eq!(max_suggestion_offset(7), 4);
        assert_eq!(max_suggestion_offset(32), 28);
    }

    #[test]
    fn status_panel_can_be_composited_over_contextual_scene() {
        let mut canvas = vec![0; 600 * 180 * 4];
        let font = load_overlay_font().unwrap();
        let mut painter = Painter::new(&mut canvas, 600, 180).unwrap();
        painter.clear();
        draw_status(
            &mut painter,
            &font,
            1,
            24,
            24,
            "DEV | wfdaemon connected",
            "Warframe running (pid 12345)",
            "DBWIN on | dbg 8 | log 2 | relic rewards",
        );
        painter.finish().unwrap();

        assert_eq!(pixel(&canvas, 600, 12, 12), [0, 0, 0, 0]);
        assert!(pixel(&canvas, 600, 40, 40)[3] > 0);
        assert_eq!(pixel(&canvas, 600, 580, 160), [0, 0, 0, 0]);
    }

    #[test]
    #[ignore = "manual renderer benchmark"]
    fn benchmark_relic_scene_renderer() {
        const FRAMES: u32 = 10;
        const WIDTH: u32 = 2560;
        const HEIGHT: u32 = 1440;

        let font = load_overlay_font().unwrap();
        let platinum_icon = load_icon(include_bytes!("../assets/platinum.png")).unwrap();
        let ducat_icon = load_icon(include_bytes!("../assets/ducats.png")).unwrap();
        let suggestion_icons = SuggestionIcons::load().unwrap();
        let assets = BTreeMap::new();
        let scene = mock_relic_scene();
        let mut canvas = vec![0; (WIDTH * HEIGHT * 4) as usize];
        let started = Instant::now();
        for _ in 0..FRAMES {
            let mut painter = Painter::new(&mut canvas, WIDTH, HEIGHT).unwrap();
            painter.clear();
            draw_relic_scene(
                &mut painter,
                &font,
                &platinum_icon,
                &ducat_icon,
                &suggestion_icons,
                &assets,
                1,
                std::hint::black_box(&scene),
                Duration::ZERO,
                0,
                false,
                false,
            );
            painter.finish().unwrap();
        }
        let elapsed = started.elapsed();
        eprintln!(
            "renderer benchmark: {FRAMES} frames in {elapsed:?}, {:.3} ms/frame",
            elapsed.as_secs_f64() * 1000.0 / f64::from(FRAMES)
        );
        std::hint::black_box(canvas);
    }

    fn pixel(canvas: &[u8], width: u32, x: u32, y: u32) -> [u8; 4] {
        let offset = ((y * width + x) * 4) as usize;
        canvas[offset..offset + 4].try_into().unwrap()
    }
}
