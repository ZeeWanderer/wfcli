use fontdue::layout::{
    CoordinateSystem, HorizontalAlign, Layout, LayoutSettings, TextStyle, VerticalAlign,
};
use fontdue::{Font, FontSettings};
use image::RgbaImage;

mod blend2d;

/// Blend2D painter borrowing a premultiplied BGRA Wayland SHM buffer.
///
/// Blend2D runs synchronously here, so temporary icon and glyph-mask buffers only
/// need to remain alive for their individual draw calls.
pub(crate) struct Painter<'a> {
    context: blend2d::Context<'a>,
}

pub(crate) use blend2d::Error as PainterError;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct TextBox {
    pub(crate) x: u32,
    pub(crate) y: u32,
    pub(crate) width: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct TextLine {
    pub(crate) x: u32,
    pub(crate) y: u32,
    pub(crate) height: u32,
}

impl TextLine {
    pub(crate) const fn new(x: u32, y: u32, height: u32) -> Self {
        Self { x, y, height }
    }
}

impl TextBox {
    pub(crate) const fn new(x: u32, y: u32, width: u32) -> Self {
        Self { x, y, width }
    }
}

impl<'a> Painter<'a> {
    pub(crate) fn new(pixels: &'a mut [u8], width: u32, height: u32) -> Result<Self, PainterError> {
        Ok(Self {
            context: blend2d::Context::new(pixels, width, height)?,
        })
    }

    pub(crate) fn width(&self) -> u32 {
        self.context.width()
    }

    pub(crate) fn height(&self) -> u32 {
        self.context.height()
    }

    pub(crate) fn clear(&mut self) {
        self.context.clear_all();
    }

    pub(crate) fn fill_rounded_rect(
        &mut self,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        radius: u32,
        color: [u8; 4],
    ) {
        if width == 0 || height == 0 {
            return;
        }
        let radius = radius.min(width / 2).min(height / 2);
        self.context.fill_round_rect_rgba32(
            f64::from(x),
            f64::from(y),
            f64::from(width),
            f64::from(height),
            f64::from(radius),
            blend2d_rgba32(color),
        );
    }

    #[cfg(test)]
    pub(crate) fn fill_panel(&mut self, radius: u32, color: [u8; 4]) {
        self.fill_rounded_rect(0, 0, self.width(), self.height(), radius, color);
    }

    pub(crate) fn draw_ring(
        &mut self,
        center_x: u32,
        center_y: u32,
        radius: u32,
        stroke: u32,
        color: [u8; 4],
    ) {
        if stroke == 0 {
            return;
        }
        self.context.stroke_circle_rgba32(
            f64::from(center_x),
            f64::from(center_y),
            f64::from(radius),
            f64::from(stroke),
            blend2d_rgba32(color),
        );
    }

    pub(crate) fn draw_image(
        &mut self,
        image: &RasterImage,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    ) {
        if width == 0 || height == 0 || image.width == 0 || image.height == 0 {
            return;
        }
        self.context.blit_scaled_prgb32(
            blend2d::Image {
                pixels: &image.pixels,
                width: image.width,
                height: image.height,
            },
            blend2d::Rect {
                x,
                y,
                width,
                height,
            },
        );
    }

    pub(crate) fn draw_image_contained(
        &mut self,
        image: &RasterImage,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    ) {
        let (draw_width, draw_height) = contained_size(image.width, image.height, width, height);
        self.draw_image(
            image,
            x + width.saturating_sub(draw_width) / 2,
            y + height.saturating_sub(draw_height) / 2,
            draw_width,
            draw_height,
        );
    }

    pub(crate) fn draw_image_contained_circle(
        &mut self,
        image: &RasterImage,
        x: u32,
        y: u32,
        diameter: u32,
    ) {
        if diameter == 0 || image.width == 0 || image.height == 0 {
            return;
        }
        let (draw_width, draw_height) =
            contained_size(image.width, image.height, diameter, diameter);
        self.context.fill_circle_prgb32(
            blend2d::Image {
                pixels: &image.pixels,
                width: image.width,
                height: image.height,
            },
            blend2d::Rect {
                x: x + diameter.saturating_sub(draw_width) / 2,
                y: y + diameter.saturating_sub(draw_height) / 2,
                width: draw_width,
                height: draw_height,
            },
            blend2d::Circle {
                x: f64::from(x) + f64::from(diameter) / 2.0,
                y: f64::from(y) + f64::from(diameter) / 2.0,
                radius: f64::from(diameter) / 2.0,
            },
        );
    }

    pub(crate) fn draw_text(
        &mut self,
        font: &Font,
        x: u32,
        y: u32,
        size: f32,
        text: &str,
        color: [u8; 4],
    ) {
        let fonts = std::slice::from_ref(font);
        let mut layout = Layout::new(CoordinateSystem::PositiveYDown);
        layout.reset(&LayoutSettings {
            x: x as f32,
            y: y as f32,
            ..LayoutSettings::default()
        });
        layout.append(fonts, &TextStyle::new(text, size, 0));
        self.draw_glyphs(font, &layout, color);
    }

    pub(crate) fn draw_text_vertically_centered(
        &mut self,
        font: &Font,
        line: TextLine,
        size: f32,
        text: &str,
        color: [u8; 4],
    ) {
        let fonts = std::slice::from_ref(font);
        let mut layout = Layout::new(CoordinateSystem::PositiveYDown);
        layout.reset(&LayoutSettings {
            x: line.x as f32,
            y: line.y as f32,
            max_height: Some(line.height as f32),
            vertical_align: VerticalAlign::Middle,
            ..LayoutSettings::default()
        });
        layout.append(fonts, &TextStyle::new(text, size, 0));
        self.draw_glyphs(font, &layout, color);
    }

    pub(crate) fn draw_centered_text(
        &mut self,
        font: &Font,
        bounds: TextBox,
        size: f32,
        text: &str,
        color: [u8; 4],
    ) {
        let fonts = std::slice::from_ref(font);
        let mut layout = Layout::new(CoordinateSystem::PositiveYDown);
        layout.reset(&LayoutSettings {
            x: bounds.x as f32,
            y: bounds.y as f32,
            max_width: Some(bounds.width as f32),
            horizontal_align: HorizontalAlign::Center,
            ..LayoutSettings::default()
        });
        layout.append(fonts, &TextStyle::new(text, size, 0));
        self.draw_glyphs(font, &layout, color);
    }

    pub(crate) fn finish(self) -> Result<(), PainterError> {
        self.context.finish()
    }

    fn draw_glyphs(&mut self, font: &Font, layout: &Layout, color: [u8; 4]) {
        for glyph in layout.glyphs() {
            if self.context.failed() {
                return;
            }
            let (_metrics, coverage) = font.rasterize_config(glyph.key);
            self.draw_mask(
                &coverage,
                glyph.width,
                glyph.height,
                glyph.x.round() as i32,
                glyph.y.round() as i32,
                color,
            );
        }
    }

    fn draw_mask(
        &mut self,
        coverage: &[u8],
        width: usize,
        height: usize,
        x: i32,
        y: i32,
        color: [u8; 4],
    ) {
        if width == 0 || height == 0 {
            return;
        }
        self.context.fill_a8_mask_rgba32(
            blend2d::Mask {
                coverage,
                width,
                height,
            },
            x,
            y,
            blend2d_rgba32(color),
        );
    }
}

pub(crate) struct RasterImage {
    pixels: Vec<u8>,
    width: u32,
    height: u32,
}

pub(crate) fn fit_text_size(
    font: &Font,
    text: &str,
    preferred: f32,
    minimum: f32,
    max_width: u32,
) -> f32 {
    let mut size = preferred;
    while size > minimum && text_width(font, text, size) > max_width as f32 {
        size -= 0.5;
    }
    size
}

pub(crate) fn text_width(font: &Font, text: &str, size: f32) -> f32 {
    text.chars()
        .map(|character| font.metrics(character, size).advance_width)
        .sum()
}

pub(crate) fn load_icon(bytes: &[u8]) -> Result<RasterImage, Box<dyn std::error::Error>> {
    let image = image::load_from_memory(bytes)?.into_rgba8();
    let mut pixels = Vec::with_capacity(image.len());
    for pixel in image.pixels() {
        let [red, green, blue, alpha] = pixel.0;
        pixels.extend_from_slice(&[
            premultiply(blue, alpha),
            premultiply(green, alpha),
            premultiply(red, alpha),
            alpha,
        ]);
    }
    Ok(RasterImage {
        pixels,
        width: image.width(),
        height: image.height(),
    })
}

pub(crate) fn load_overlay_font() -> Result<Font, Box<dyn std::error::Error>> {
    Font::from_bytes(
        include_bytes!("../assets/Roboto-Regular.ttf").as_slice(),
        FontSettings::default(),
    )
    .map_err(Into::into)
}

/// Convert conventional CSS/RGBA channel order to little-endian ARGB8888 SHM bytes.
pub(crate) const fn css_rgba(red: u8, green: u8, blue: u8, alpha: u8) -> [u8; 4] {
    [blue, green, red, alpha]
}

pub(crate) fn straight_rgba(source: &[u8], width: u32, height: u32) -> Result<RgbaImage, String> {
    let mut destination = Vec::with_capacity(source.len());
    for pixel in source.chunks_exact(4) {
        let alpha = u32::from(pixel[3]);
        for channel in [pixel[2], pixel[1], pixel[0]] {
            let value = (u32::from(channel) * 255)
                .checked_div(alpha)
                .unwrap_or(0)
                .min(255) as u8;
            destination.push(value);
        }
        destination.push(pixel[3]);
    }
    RgbaImage::from_raw(width, height, destination)
        .ok_or_else(|| "overlay preview buffer has invalid dimensions".to_owned())
}

const fn blend2d_rgba32(color: [u8; 4]) -> u32 {
    let [blue, green, red, alpha] = color;
    u32::from_be_bytes([alpha, red, green, blue])
}

const fn premultiply(channel: u8, alpha: u8) -> u8 {
    ((channel as u16 * alpha as u16 + 127) / 255) as u8
}

fn contained_size(source_width: u32, source_height: u32, width: u32, height: u32) -> (u32, u32) {
    if source_width == 0 || source_height == 0 || width == 0 || height == 0 {
        return (0, 0);
    }
    if u64::from(source_width) * u64::from(height) > u64::from(source_height) * u64::from(width) {
        let height = ((u128::from(source_height) * u128::from(width)
            + u128::from(source_width) / 2)
            / u128::from(source_width))
        .max(1) as u32;
        (width, height)
    } else {
        let width = ((u128::from(source_width) * u128::from(height)
            + u128::from(source_height) / 2)
            / u128::from(source_height))
        .max(1) as u32;
        (width, height)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loads_webp_assets_from_daemon_cache() {
        let mut encoded = Vec::new();
        image::codecs::webp::WebPEncoder::new_lossless(&mut encoded)
            .encode(&[10, 20, 30, 255], 1, 1, image::ExtendedColorType::Rgba8)
            .unwrap();

        let image = load_icon(&encoded).unwrap();
        assert_eq!((image.width, image.height), (1, 1));
        assert_eq!(image.pixels, [30, 20, 10, 255]);
    }

    #[test]
    fn rounded_panel_antialiases_corners() {
        let mut pixels = vec![0; 8 * 8 * 4];
        let color = [1, 2, 3, 255];
        let mut painter = Painter::new(&mut pixels, 8, 8).unwrap();
        painter.fill_panel(2, color);
        painter.finish().unwrap();

        assert!(pixel(&pixels, 8, 0, 0)[3] < 128);
        assert!(pixel(&pixels, 8, 7, 0)[3] < 128);
        assert!(pixel(&pixels, 8, 2, 0)[3] > 128);
        assert_eq!(pixel(&pixels, 8, 4, 4), color);
    }

    #[test]
    fn oversized_radius_is_clamped() {
        let mut pixels = vec![0; 4 * 2 * 4];
        let mut painter = Painter::new(&mut pixels, 4, 2).unwrap();
        painter.fill_panel(u32::MAX, [1, 2, 3, 255]);
        painter.finish().unwrap();
    }

    #[test]
    fn glyph_mask_blends_over_panel() {
        let mut pixels = vec![0; 4];
        let mut painter = Painter::new(&mut pixels, 1, 1).unwrap();
        painter.fill_panel(0, [10, 20, 30, 200]);
        painter.draw_mask(&[128], 1, 1, 0, 0, [110, 120, 130, 255]);
        painter.finish().unwrap();

        assert!((226..=229).contains(&pixels[3]));
        assert!(pixels[0] < pixels[1]);
        assert!(pixels[1] < pixels[2]);
    }

    #[test]
    fn circular_image_keeps_wide_texture_centered() {
        let image = RasterImage {
            pixels: vec![255; 8 * 4 * 4],
            width: 8,
            height: 4,
        };
        let mut pixels = vec![0; 8 * 8 * 4];
        let mut painter = Painter::new(&mut pixels, 8, 8).unwrap();
        painter.draw_image_contained_circle(&image, 0, 0, 8);
        painter.finish().unwrap();

        assert_eq!(pixel(&pixels, 8, 0, 0)[3], 0);
        assert_eq!(pixel(&pixels, 8, 4, 1)[3], 0);
        assert_eq!(pixel(&pixels, 8, 4, 4)[3], 255);
    }

    #[test]
    fn blend2d_writes_into_borrowed_buffer() {
        let mut pixels = vec![0; 4 * 4 * 4];
        let mut painter = Painter::new(&mut pixels, 4, 4).unwrap();
        painter.fill_panel(0, css_rgba(16, 22, 35, 255));
        painter.finish().unwrap();

        assert_eq!(pixel(&pixels, 4, 2, 2), [35, 22, 16, 255]);
    }

    #[test]
    fn contained_image_preserves_aspect_ratio_and_centers() {
        let image = RasterImage {
            pixels: vec![255; 4 * 2 * 4],
            width: 4,
            height: 2,
        };
        let mut pixels = vec![0; 8 * 8 * 4];
        let mut painter = Painter::new(&mut pixels, 8, 8).unwrap();
        painter.draw_image_contained(&image, 0, 0, 8, 8);
        painter.finish().unwrap();

        assert_eq!(pixel(&pixels, 8, 4, 1)[3], 0);
        assert_eq!(pixel(&pixels, 8, 4, 2)[3], 255);
        assert_eq!(pixel(&pixels, 8, 4, 5)[3], 255);
        assert_eq!(pixel(&pixels, 8, 4, 6)[3], 0);
    }

    #[test]
    fn currency_icons_match_reference_contain_sizes() {
        assert_eq!(contained_size(333, 285, 28, 28), (28, 24));
        assert_eq!(contained_size(64, 64, 30, 30), (30, 30));
    }

    #[test]
    fn contained_image_downsampling_has_smooth_alpha_edges() {
        let image = RasterImage {
            pixels: vec![0, 0, 0, 0, 255, 255, 255, 255],
            width: 2,
            height: 1,
        };
        let mut pixels = vec![0; 4 * 2 * 4];
        let mut painter = Painter::new(&mut pixels, 4, 2).unwrap();
        painter.draw_image_contained(&image, 0, 0, 4, 2);
        painter.finish().unwrap();

        assert!(pixels.chunks_exact(4).any(|pixel| {
            let alpha = pixel[3];
            alpha > 0 && alpha < 255
        }));
    }

    #[test]
    fn bundled_font_matches_aleca_line_height() {
        let font = load_overlay_font().unwrap();
        let metrics = font.horizontal_line_metrics(19.0).unwrap();

        assert_eq!(metrics.new_line_size.ceil(), 23.0);
    }

    #[test]
    fn css_colors_are_converted_to_shm_byte_order() {
        assert_eq!(css_rgba(16, 22, 35, 255), [35, 22, 16, 255]);
        assert_eq!(blend2d_rgba32([35, 22, 16, 255]), 0xFF10_1623);
    }

    #[test]
    fn premultiplied_bgra_converts_to_straight_rgba() {
        let image = straight_rgba(&[25, 50, 100, 128, 0, 0, 0, 0], 2, 1).unwrap();
        assert_eq!(image.as_raw(), &[199, 99, 49, 128, 0, 0, 0, 0]);
    }

    fn pixel(pixels: &[u8], width: u32, x: u32, y: u32) -> [u8; 4] {
        let offset = ((y * width + x) * 4) as usize;
        pixels[offset..offset + 4].try_into().unwrap()
    }
}
