use std::ffi::c_int;
use std::fmt;
use std::marker::PhantomData;
use std::ptr::NonNull;

use fontdue::layout::{
    CoordinateSystem, HorizontalAlign, Layout, LayoutSettings, TextStyle, VerticalAlign,
};
use fontdue::{Font, FontSettings};
use image::RgbaImage;

const BL_SUCCESS: u32 = 0;

#[repr(C)]
struct WfBlendPainter {
    _private: [u8; 0],
}

unsafe extern "C" {
    fn wf_bl_painter_create(
        pixels: *mut u8,
        width: c_int,
        height: c_int,
        stride: isize,
        result_out: *mut u32,
    ) -> *mut WfBlendPainter;
    fn wf_bl_painter_destroy(painter: *mut WfBlendPainter) -> u32;
    fn wf_bl_clear(painter: *mut WfBlendPainter) -> u32;
    fn wf_bl_fill_round_rect(
        painter: *mut WfBlendPainter,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        radius: f64,
        rgba32: u32,
    ) -> u32;
    fn wf_bl_stroke_circle(
        painter: *mut WfBlendPainter,
        center_x: f64,
        center_y: f64,
        radius: f64,
        stroke_width: f64,
        rgba32: u32,
    ) -> u32;
    fn wf_bl_blit_prgb32(
        painter: *mut WfBlendPainter,
        pixels: *const u8,
        source_width: c_int,
        source_height: c_int,
        source_stride: isize,
        target_x: c_int,
        target_y: c_int,
        target_width: c_int,
        target_height: c_int,
    ) -> u32;
    fn wf_bl_fill_circle_prgb32(
        painter: *mut WfBlendPainter,
        pixels: *const u8,
        source_width: c_int,
        source_height: c_int,
        source_stride: isize,
        target_x: c_int,
        target_y: c_int,
        target_width: c_int,
        target_height: c_int,
        center_x: f64,
        center_y: f64,
        radius: f64,
    ) -> u32;
    fn wf_bl_fill_a8_mask(
        painter: *mut WfBlendPainter,
        coverage: *const u8,
        width: c_int,
        height: c_int,
        stride: isize,
        target_x: c_int,
        target_y: c_int,
        rgba32: u32,
    ) -> u32;
}

/// Blend2D painter borrowing a premultiplied BGRA Wayland SHM buffer.
///
/// Blend2D runs synchronously here, so temporary icon and glyph-mask buffers only
/// need to remain alive for their individual draw calls.
pub(crate) struct Painter<'a> {
    handle: Option<NonNull<WfBlendPainter>>,
    width: u32,
    height: u32,
    error: Option<PainterError>,
    _pixels: PhantomData<&'a mut [u8]>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct TextBox {
    pub(crate) x: u32,
    pub(crate) y: u32,
    pub(crate) width: u32,
}

impl TextBox {
    pub(crate) const fn new(x: u32, y: u32, width: u32) -> Self {
        Self { x, y, width }
    }
}

#[derive(Debug)]
pub(crate) struct PainterError {
    operation: &'static str,
    code: Option<u32>,
}

impl PainterError {
    fn invalid(operation: &'static str) -> Self {
        Self {
            operation,
            code: None,
        }
    }

    fn blend2d(operation: &'static str, code: u32) -> Self {
        Self {
            operation,
            code: Some(code),
        }
    }
}

impl fmt::Display for PainterError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.code {
            Some(code) => write!(
                formatter,
                "Blend2D {} failed with BLResult {code:#010x}",
                self.operation
            ),
            None => write!(formatter, "invalid Blend2D {} arguments", self.operation),
        }
    }
}

impl std::error::Error for PainterError {}

impl<'a> Painter<'a> {
    pub(crate) fn new(pixels: &'a mut [u8], width: u32, height: u32) -> Result<Self, PainterError> {
        let width_i32 = i32::try_from(width).map_err(|_| PainterError::invalid("image width"))?;
        let height_i32 =
            i32::try_from(height).map_err(|_| PainterError::invalid("image height"))?;
        let stride = width
            .checked_mul(4)
            .and_then(|value| isize::try_from(value).ok())
            .ok_or_else(|| PainterError::invalid("image stride"))?;
        let expected_len = usize::try_from(stride)
            .ok()
            .and_then(|stride| stride.checked_mul(height as usize))
            .ok_or_else(|| PainterError::invalid("image dimensions"))?;
        if pixels.len() < expected_len {
            return Err(PainterError::invalid("image buffer"));
        }

        let mut result = BL_SUCCESS;
        let handle = unsafe {
            wf_bl_painter_create(
                pixels.as_mut_ptr(),
                width_i32,
                height_i32,
                stride,
                &mut result,
            )
        };
        let handle = NonNull::new(handle)
            .ok_or_else(|| PainterError::blend2d("context creation", result))?;
        Ok(Self {
            handle: Some(handle),
            width,
            height,
            error: None,
            _pixels: PhantomData,
        })
    }

    pub(crate) fn width(&self) -> u32 {
        self.width
    }

    pub(crate) fn height(&self) -> u32 {
        self.height
    }

    pub(crate) fn clear(&mut self) {
        let result = unsafe { wf_bl_clear(self.raw()) };
        self.record("clear", result);
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
        if width == 0 || height == 0 || self.error.is_some() {
            return;
        }
        let radius = radius.min(width / 2).min(height / 2);
        let result = unsafe {
            wf_bl_fill_round_rect(
                self.raw(),
                f64::from(x),
                f64::from(y),
                f64::from(width),
                f64::from(height),
                f64::from(radius),
                blend2d_rgba32(color),
            )
        };
        self.record("rounded rectangle", result);
    }

    #[cfg(test)]
    pub(crate) fn fill_panel(&mut self, radius: u32, color: [u8; 4]) {
        self.fill_rounded_rect(0, 0, self.width, self.height, radius, color);
    }

    pub(crate) fn draw_ring(
        &mut self,
        center_x: u32,
        center_y: u32,
        radius: u32,
        stroke: u32,
        color: [u8; 4],
    ) {
        if stroke == 0 || self.error.is_some() {
            return;
        }
        let result = unsafe {
            wf_bl_stroke_circle(
                self.raw(),
                f64::from(center_x),
                f64::from(center_y),
                f64::from(radius),
                f64::from(stroke),
                blend2d_rgba32(color),
            )
        };
        self.record("circle stroke", result);
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
        let result = unsafe {
            wf_bl_blit_prgb32(
                self.raw(),
                image.pixels.as_ptr(),
                image.width as i32,
                image.height as i32,
                (image.width * 4) as isize,
                x as i32,
                y as i32,
                width as i32,
                height as i32,
            )
        };
        self.record("image blit", result);
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
        let result = unsafe {
            wf_bl_fill_circle_prgb32(
                self.raw(),
                image.pixels.as_ptr(),
                image.width as i32,
                image.height as i32,
                (image.width * 4) as isize,
                (x + diameter.saturating_sub(draw_width) / 2) as i32,
                (y + diameter.saturating_sub(draw_height) / 2) as i32,
                draw_width as i32,
                draw_height as i32,
                f64::from(x) + f64::from(diameter) / 2.0,
                f64::from(y) + f64::from(diameter) / 2.0,
                f64::from(diameter) / 2.0,
            )
        };
        self.record("circular image fill", result);
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
        x: u32,
        y: u32,
        height: u32,
        size: f32,
        text: &str,
        color: [u8; 4],
    ) {
        let fonts = std::slice::from_ref(font);
        let mut layout = Layout::new(CoordinateSystem::PositiveYDown);
        layout.reset(&LayoutSettings {
            x: x as f32,
            y: y as f32,
            max_height: Some(height as f32),
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

    pub(crate) fn finish(mut self) -> Result<(), PainterError> {
        let handle = self.handle.take().expect("Blend2D painter handle");
        let finish_result = unsafe { wf_bl_painter_destroy(handle.as_ptr()) };
        if let Some(error) = self.error.take() {
            return Err(error);
        }
        if finish_result != BL_SUCCESS {
            return Err(PainterError::blend2d("context finish", finish_result));
        }
        Ok(())
    }

    fn draw_glyphs(&mut self, font: &Font, layout: &Layout, color: [u8; 4]) {
        for glyph in layout.glyphs() {
            if self.error.is_some() {
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
        if width == 0 || height == 0 || self.error.is_some() {
            return;
        }
        let result = unsafe {
            wf_bl_fill_a8_mask(
                self.raw(),
                coverage.as_ptr(),
                width as i32,
                height as i32,
                width as isize,
                x,
                y,
                blend2d_rgba32(color),
            )
        };
        self.record("glyph mask", result);
    }

    fn raw(&self) -> *mut WfBlendPainter {
        self.handle.expect("Blend2D painter handle").as_ptr()
    }

    fn record(&mut self, operation: &'static str, result: u32) {
        if result != BL_SUCCESS && self.error.is_none() {
            self.error = Some(PainterError::blend2d(operation, result));
        }
    }
}

impl Drop for Painter<'_> {
    fn drop(&mut self) {
        if let Some(handle) = self.handle.take() {
            unsafe {
                wf_bl_painter_destroy(handle.as_ptr());
            }
        }
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
