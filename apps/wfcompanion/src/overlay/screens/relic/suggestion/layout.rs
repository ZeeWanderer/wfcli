use crate::ui::Rect;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Layout {
    pub(super) shell: Rect,
    pub(super) header: Rect,
    pub(super) close: Rect,
    pub(super) grid: Rect,
    pub(super) cards: Vec<Rect>,
    pub(super) footer: Rect,
}

impl Layout {
    pub(super) fn scaled(mut self, scale: u32) -> Self {
        self.shell = self.shell.scaled(scale);
        self.header = self.header.scaled(scale);
        self.close = self.close.scaled(scale);
        self.grid = self.grid.scaled(scale);
        self.footer = self.footer.scaled(scale);
        self.cards = self
            .cards
            .into_iter()
            .map(|card| card.scaled(scale))
            .collect();
        self
    }
}

pub(super) fn compute(screen_width: u32, screen_height: u32, item_count: usize) -> Layout {
    let margin = 20.min(screen_width / 2).min(screen_height / 2);
    let width = 480.min(screen_width.saturating_sub(margin));
    let height = 220.min(screen_height.saturating_sub(margin));
    let shell = Rect {
        x: screen_width.saturating_sub(width + margin),
        y: margin,
        width,
        height,
    };
    let inner = shell.inset(2.min(width / 2).min(height / 2));
    let header_height = 44.min(inner.height);
    let footer_height = 31.min(inner.height.saturating_sub(header_height));
    let header = Rect {
        x: inner.x,
        y: inner.y,
        width: inner.width,
        height: header_height,
    };
    let footer = Rect {
        x: inner.x,
        y: inner.y + inner.height.saturating_sub(footer_height),
        width: inner.width,
        height: footer_height,
    };
    let grid = Rect {
        x: inner.x,
        y: header.y + header.height,
        width: inner.width,
        height: inner.height.saturating_sub(header_height + footer_height),
    };
    let gap = 5;
    let padding = 5.min(grid.width / 2).min(grid.height / 2);
    let card_width = grid
        .width
        .saturating_sub(padding * 2 + gap)
        .checked_div(2)
        .unwrap_or(0);
    let card_height = grid
        .height
        .saturating_sub(padding * 2 + gap)
        .checked_div(2)
        .unwrap_or(0);
    let cards = (0..item_count.min(4))
        .map(|index| Rect {
            x: grid.x + padding + (index as u32 % 2) * (card_width + gap),
            y: grid.y + padding + (index as u32 / 2) * (card_height + gap),
            width: card_width,
            height: card_height,
        })
        .collect();
    let close = Rect {
        x: header.x + header.width.saturating_sub(35),
        y: header.y + 8,
        width: 28,
        height: 28,
    };
    Layout {
        shell,
        header,
        close,
        grid,
        cards,
        footer,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_aleca_reference() {
        let layout = compute(2560, 1440, 4);
        assert_eq!(
            layout.shell,
            Rect {
                x: 2060,
                y: 20,
                width: 480,
                height: 220,
            }
        );
        assert_eq!(layout.header.height, 44);
        assert_eq!(
            layout.close,
            Rect {
                x: 2503,
                y: 30,
                width: 28,
                height: 28,
            }
        );
        assert_eq!(layout.grid.height, 141);
        assert_eq!(layout.cards.len(), 4);
        assert_eq!(layout.cards[0].width, 230);
        assert_eq!(layout.cards[0].height, 63);
        assert_eq!(layout.footer.height, 31);
    }
}
