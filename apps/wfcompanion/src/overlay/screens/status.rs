use fontdue::Font;

use crate::painter::Painter;

pub(in crate::overlay) const WIDTH: u32 = 420;
pub(in crate::overlay) const HEIGHT: u32 = 90;
pub(in crate::overlay) const INSET: u32 = 16;

#[allow(clippy::too_many_arguments)]
pub(super) fn draw(
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
