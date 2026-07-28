use std::path::Path;
use std::time::Duration;

use fontdue::Font;
use image::ImageFormat;

use crate::painter::{Painter, load_overlay_font, straight_rgba};
use crate::ui::ScreenOutput;

use super::scene::{RelicView, Scene};
use super::screens::{self, Assets, mock_relic_scene};

pub(super) const LOADING_FRAME_INTERVAL: Duration = Duration::from_nanos(1_000_000_000 / 30);

pub(super) struct Renderer {
    font: Font,
    assets: Assets,
    frame: Option<Frame>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct FrameKey {
    pub(super) width: u32,
    pub(super) height: u32,
    pub(super) scale: u32,
    pub(super) scene: Scene,
}

pub(super) struct Frame {
    pub(super) key: FrameKey,
    pub(super) pixels: Vec<u8>,
    pub(super) output: ScreenOutput,
}

impl Renderer {
    pub(super) fn load() -> Result<Self, Box<dyn std::error::Error>> {
        Ok(Self {
            font: load_overlay_font()?,
            assets: Assets::load()?,
            frame: None,
        })
    }

    pub(super) fn cache_scene_assets(&mut self, scene: &crate::relic::Scene) {
        self.assets.cache_relic_scene(scene);
    }

    pub(super) fn prepare_frame(&mut self, key: FrameKey) -> Result<bool, String> {
        ensure_frame(&mut self.frame, key, &self.font, &self.assets)
    }

    pub(super) fn frame(&self) -> Option<&Frame> {
        self.frame.as_ref()
    }

    pub(super) fn draw_animation(&self, painter: &mut Painter<'_>, elapsed: Duration) {
        if let Some(frame) = self.frame.as_ref() {
            screens::draw_animation(
                painter,
                &frame.key.scene,
                &frame.output,
                frame.key.scale,
                elapsed,
            );
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn draw_status(
        &self,
        painter: &mut Painter<'_>,
        scale: u32,
        x: u32,
        y: u32,
        daemon: &str,
        player: &str,
        detail: &str,
    ) {
        screens::draw_status(painter, &self.font, scale, x, y, daemon, player, detail);
    }
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
    let renderer =
        Renderer::load().map_err(|error| format!("could not load overlay renderer: {error}"))?;
    let mut painter = Painter::new(&mut overlay, width, height)
        .map_err(|error| format!("could not create overlay painter: {error}"))?;
    let scene = Scene::Relic {
        content: scene.clone(),
        view: RelicView {
            suggestion_offset: 0,
            interaction_active: false,
            close_hovered: false,
        },
    };
    let output = screens::draw_static(&mut painter, &renderer.font, &renderer.assets, &scene, 1);
    screens::draw_animation(&mut painter, &scene, &output, 1, elapsed);
    painter
        .finish()
        .map_err(|error| format!("could not render overlay: {error}"))?;

    straight_rgba(&overlay, width, height)
}

fn render_notification_preview(dimensions: (u32, u32)) -> Result<image::RgbaImage, String> {
    let mut surface = vec![0; (screens::STATUS_WIDTH * screens::STATUS_HEIGHT * 4) as usize];
    let renderer =
        Renderer::load().map_err(|error| format!("could not load overlay renderer: {error}"))?;
    let mut painter = Painter::new(&mut surface, screens::STATUS_WIDTH, screens::STATUS_HEIGHT)
        .map_err(|error| format!("could not create overlay painter: {error}"))?;
    painter.clear();
    renderer.draw_status(
        &mut painter,
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
        screens::STATUS_WIDTH,
        screens::STATUS_HEIGHT,
        screens::STATUS_INSET,
        screens::STATUS_INSET,
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

fn ensure_frame(
    cache: &mut Option<Frame>,
    key: FrameKey,
    font: &Font,
    assets: &Assets,
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
    let output = screens::draw_static(&mut painter, font, assets, &key.scene, key.scale);
    painter
        .finish()
        .map_err(|error| format!("could not render relic frame: {error}"))?;
    *cache = Some(Frame {
        key,
        pixels,
        output,
    });
    Ok(true)
}

#[cfg(test)]
mod tests {
    use std::time::Instant;

    use super::*;

    #[test]
    fn static_relic_frame_is_reused_until_scene_changes() {
        let mut renderer = Renderer::load().unwrap();
        let key = FrameKey {
            width: 2560,
            height: 1440,
            scale: 1,
            scene: Scene::Relic {
                content: mock_relic_scene(),
                view: RelicView {
                    suggestion_offset: 0,
                    interaction_active: false,
                    close_hovered: false,
                },
            },
        };

        assert!(renderer.prepare_frame(key.clone()).unwrap());
        assert!(!renderer.prepare_frame(key).unwrap());
        assert!(renderer.frame().unwrap().output.animation_bounds.is_none());

        let reading = FrameKey {
            width: 2560,
            height: 1440,
            scale: 1,
            scene: Scene::Relic {
                content: crate::relic::Scene::Reading,
                view: RelicView {
                    suggestion_offset: 0,
                    interaction_active: false,
                    close_hovered: false,
                },
            },
        };
        assert!(renderer.prepare_frame(reading).unwrap());
        assert!(renderer.frame().unwrap().output.animation_bounds.is_some());
    }

    #[test]
    fn suggestion_frame_exposes_rendered_hit_regions() {
        let mut renderer = Renderer::load().unwrap();
        let content = crate::relic::suggestion_fixture().unwrap();
        renderer
            .prepare_frame(FrameKey {
                width: 2560,
                height: 1440,
                scale: 1,
                scene: Scene::Relic {
                    content,
                    view: RelicView {
                        suggestion_offset: 0,
                        interaction_active: true,
                        close_hovered: false,
                    },
                },
            })
            .unwrap();

        let output = &renderer.frame().unwrap().output;
        assert!(output.contains(crate::ui::HitTarget::Content, (2060.0, 20.0)));
        assert!(output.contains(crate::ui::HitTarget::Close, (2503.0, 30.0)));
        assert!(output.contains(crate::ui::HitTarget::Scroll, (2062.0, 66.0)));
        assert!(!output.contains(crate::ui::HitTarget::Content, (2059.0, 20.0)));
    }

    #[test]
    fn status_panel_can_be_composited_over_contextual_scene() {
        let mut canvas = vec![0; 600 * 180 * 4];
        let renderer = Renderer::load().unwrap();
        let mut painter = Painter::new(&mut canvas, 600, 180).unwrap();
        painter.clear();
        renderer.draw_status(
            &mut painter,
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
        let mut renderer = Renderer::load().unwrap();
        let started = Instant::now();
        for frame in 0..FRAMES {
            renderer
                .prepare_frame(FrameKey {
                    width: 2560,
                    height: 1440,
                    scale: 1,
                    scene: Scene::Relic {
                        content: mock_relic_scene(),
                        view: RelicView {
                            suggestion_offset: frame as usize,
                            interaction_active: false,
                            close_hovered: false,
                        },
                    },
                })
                .unwrap();
        }
        let elapsed = started.elapsed();
        eprintln!(
            "renderer benchmark: {FRAMES} frames in {elapsed:?}, {:.3} ms/frame",
            elapsed.as_secs_f64() * 1000.0 / f64::from(FRAMES)
        );
    }

    fn pixel(canvas: &[u8], width: u32, x: u32, y: u32) -> [u8; 4] {
        let offset = ((y * width + x) * 4) as usize;
        canvas[offset..offset + 4].try_into().unwrap()
    }
}
