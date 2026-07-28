#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Rect {
    pub(crate) x: u32,
    pub(crate) y: u32,
    pub(crate) width: u32,
    pub(crate) height: u32,
}

impl Rect {
    pub(crate) fn contains(self, x: f64, y: f64) -> bool {
        x >= f64::from(self.x)
            && y >= f64::from(self.y)
            && x < f64::from(self.x + self.width)
            && y < f64::from(self.y + self.height)
    }

    pub(crate) fn scaled(self, scale: u32) -> Self {
        Self {
            x: self.x * scale,
            y: self.y * scale,
            width: self.width * scale,
            height: self.height * scale,
        }
    }

    pub(crate) fn inset(self, inset: u32) -> Self {
        let horizontal = inset.saturating_mul(2).min(self.width);
        let vertical = inset.saturating_mul(2).min(self.height);
        Self {
            x: self.x + horizontal / 2,
            y: self.y + vertical / 2,
            width: self.width - horizontal,
            height: self.height - vertical,
        }
    }

    pub(crate) fn intersection(self, other: Self) -> Self {
        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        let right = self
            .x
            .saturating_add(self.width)
            .min(other.x.saturating_add(other.width));
        let bottom = self
            .y
            .saturating_add(self.height)
            .min(other.y.saturating_add(other.height));
        Self {
            x,
            y,
            width: right.saturating_sub(x),
            height: bottom.saturating_sub(y),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum HitTarget {
    Content,
    Close,
    Scroll,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct HitRegion {
    pub(crate) target: HitTarget,
    pub(crate) bounds: Rect,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct ScreenOutput {
    pub(crate) animation_bounds: Option<Rect>,
    pub(crate) hit_regions: Vec<HitRegion>,
}

impl ScreenOutput {
    pub(crate) fn contains(&self, target: HitTarget, position: (f64, f64)) -> bool {
        self.hit_regions
            .iter()
            .any(|region| region.target == target && region.bounds.contains(position.0, position.1))
    }
}
