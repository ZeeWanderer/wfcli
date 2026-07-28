use taffy::geometry::Rect as TaffyRect;
use taffy::prelude::*;

use crate::ui::Rect;
use crate::ui::layout::UiTree;

const REFERENCE_HEIGHT: f64 = 1080.0;
const REFERENCE_WIDTH: f64 = 1000.0;
const REFERENCE_TOP: f64 = 630.0;
const WINDOW_HEIGHT: u32 = 355;
const WINDOW_CHROME_WIDTH: u32 = 20;
const WINDOW_OFFSET: f64 = 15.0;

#[derive(Clone, Copy, Debug)]
pub(super) struct CardSpec {
    pub(super) platinum_width: f32,
    pub(super) ducats_width: f32,
    pub(super) vaulted: bool,
    pub(super) favorite: bool,
}

impl Default for CardSpec {
    fn default() -> Self {
        Self {
            platinum_width: 42.0,
            ducats_width: 44.0,
            vaulted: false,
            favorite: false,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct CardLayout {
    pub(super) card: Rect,
    pub(super) name: Rect,
    pub(super) prices: Rect,
    pub(super) platinum: Rect,
    pub(super) vaulted: Option<Rect>,
    pub(super) ducats: Rect,
    pub(super) ownership: Rect,
    pub(super) components: Rect,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Layout {
    pub(super) window: Rect,
    pub(super) shell: Rect,
    pub(super) holder: Rect,
    pub(super) cards: Rect,
    pub(super) footer: Rect,
    pub(super) reward_cards: Vec<CardLayout>,
}

impl Layout {
    pub(super) fn scaled(mut self, scale: u32) -> Self {
        self.window = self.window.scaled(scale);
        self.shell = self.shell.scaled(scale);
        self.holder = self.holder.scaled(scale);
        self.cards = self.cards.scaled(scale);
        self.footer = self.footer.scaled(scale);
        for card in &mut self.reward_cards {
            card.card = card.card.scaled(scale);
            card.name = card.name.scaled(scale);
            card.prices = card.prices.scaled(scale);
            card.platinum = card.platinum.scaled(scale);
            card.vaulted = card.vaulted.map(|bounds| bounds.scaled(scale));
            card.ducats = card.ducats.scaled(scale);
            card.ownership = card.ownership.scaled(scale);
            card.components = card.components.scaled(scale);
        }
        self
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Element {
    Root,
    Shell,
    Relic,
    Holder,
    Footer,
    Card(usize),
    Name(usize),
    Prices(usize),
    Platinum(usize),
    Vaulted(usize),
    Favorite(usize),
    Ducats(usize),
    Ownership(usize),
    Components(usize),
}

pub(super) fn compute(
    screen_width: u32,
    screen_height: u32,
    card_specs: &[CardSpec],
) -> Result<Layout, String> {
    let window = relic_overlay_bounds(screen_width, screen_height);
    let mut tree = UiTree::new();
    let mut cards = Vec::with_capacity(card_specs.len().min(4));

    for (index, spec) in card_specs.iter().take(4).enumerate() {
        let name = tree.leaf(
            Element::Name(index),
            Style {
                size: Size {
                    width: percent(1.0_f32),
                    height: length(24.85_f32),
                },
                align_self: Some(AlignSelf::CENTER),
                grid_row: line(1),
                grid_column: span(2),
                ..Default::default()
            },
        )?;
        let platinum = tree.leaf(
            Element::Platinum(index),
            Style {
                size: Size {
                    width: length(spec.platinum_width),
                    height: length(28.0_f32),
                },
                margin: TaffyRect {
                    left: length(4.0_f32),
                    right: zero(),
                    top: zero(),
                    bottom: zero(),
                },
                ..Default::default()
            },
        )?;
        let mut price_children = vec![platinum];
        if spec.vaulted {
            price_children.push(tree.leaf(
                Element::Vaulted(index),
                Style {
                    size: Size {
                        width: length(36.0_f32),
                        height: length(30.0_f32),
                    },
                    ..Default::default()
                },
            )?);
        }
        if spec.favorite {
            price_children.push(tree.leaf(
                Element::Favorite(index),
                Style {
                    size: Size {
                        width: length(27.0_f32),
                        height: length(27.0_f32),
                    },
                    ..Default::default()
                },
            )?);
        }
        let ducats = tree.leaf(
            Element::Ducats(index),
            Style {
                size: Size {
                    width: length(spec.ducats_width),
                    height: length(30.0_f32),
                },
                margin: TaffyRect {
                    left: zero(),
                    right: length(4.0_f32),
                    top: zero(),
                    bottom: zero(),
                },
                ..Default::default()
            },
        )?;
        price_children.push(ducats);
        let prices = tree.row(
            Element::Prices(index),
            Style {
                size: Size {
                    width: percent(1.0_f32),
                    height: length(30.0_f32),
                },
                align_items: Some(AlignItems::CENTER),
                align_self: Some(AlignSelf::CENTER),
                justify_content: Some(JustifyContent::SPACE_AROUND),
                grid_row: line(2),
                grid_column: span(2),
                ..Default::default()
            },
            &price_children,
        )?;
        let ownership = tree.leaf(
            Element::Ownership(index),
            Style {
                size: Size {
                    width: percent(0.8_f32),
                    height: length(27.0_f32),
                },
                align_self: Some(AlignSelf::CENTER),
                justify_self: Some(JustifySelf::CENTER),
                grid_row: line(3),
                grid_column: span(2),
                ..Default::default()
            },
        )?;
        let components = tree.leaf(
            Element::Components(index),
            Style {
                size: Size {
                    width: percent(1.0_f32),
                    height: percent(1.0_f32),
                },
                align_self: Some(AlignSelf::CENTER),
                grid_row: line(4),
                grid_column: span(2),
                ..Default::default()
            },
        )?;
        cards.push(tree.grid(
            Element::Card(index),
            Style {
                size: Size {
                    width: length(100.0_f32),
                    height: percent(1.0_f32),
                },
                max_size: Size {
                    width: percent(0.25_f32),
                    height: auto(),
                },
                padding: TaffyRect {
                    left: length(6.0_f32),
                    right: length(6.0_f32),
                    top: length(6.0_f32),
                    bottom: length(6.0_f32),
                },
                align_items: Some(AlignItems::CENTER),
                flex_grow: 1.0,
                grid_template_columns: vec![fr(1.0_f32), fr(1.0_f32)],
                grid_template_rows: vec![fr(1.05_f32), fr(0.77_f32), fr(0.8_f32), fr(1.5_f32)],
                ..Default::default()
            },
            &[name, prices, ownership, components],
        )?);
    }

    let holder = tree.row(
        Element::Holder,
        Style {
            flex_grow: 1.0,
            min_size: Size {
                width: auto(),
                height: length(0.0_f32),
            },
            padding: TaffyRect {
                left: length(7.0_f32),
                right: length(7.0_f32),
                top: length(7.0_f32),
                bottom: length(7.0_f32),
            },
            gap: Size {
                width: percent(0.005_f32),
                height: zero(),
            },
            justify_content: Some(JustifyContent::CENTER),
            ..Default::default()
        },
        &cards,
    )?;
    let footer = tree.leaf(
        Element::Footer,
        Style {
            size: Size {
                width: percent(1.0_f32),
                height: percent(0.16_f32),
            },
            flex_shrink: 0.0,
            ..Default::default()
        },
    )?;
    let relic = tree.column(
        Element::Relic,
        Style {
            flex_grow: 1.0,
            min_size: Size {
                width: length(0.0_f32),
                height: length(0.0_f32),
            },
            ..Default::default()
        },
        &[holder, footer],
    )?;
    let shell = tree.row(
        Element::Shell,
        Style {
            size: Size {
                width: percent(1.0_f32),
                height: percent(1.0_f32),
            },
            border: TaffyRect {
                left: length(2.0_f32),
                right: length(2.0_f32),
                top: length(2.0_f32),
                bottom: length(2.0_f32),
            },
            ..Default::default()
        },
        &[relic],
    )?;
    let root = tree.row(
        Element::Root,
        Style {
            size: Size {
                width: length(window.width as f32),
                height: length(window.height as f32),
            },
            padding: TaffyRect {
                left: length(15.0_f32),
                right: length(15.0_f32),
                top: length(15.0_f32),
                bottom: length(15.0_f32),
            },
            ..Default::default()
        },
        &[shell],
    )?;
    let layout = tree.compute(root, (window.x, window.y), (window.width, window.height))?;

    Ok(Layout {
        window,
        shell: layout.bounds(Element::Shell),
        holder: layout.bounds(Element::Holder),
        cards: layout.content_bounds(Element::Holder),
        footer: layout.bounds(Element::Footer),
        reward_cards: card_specs
            .iter()
            .take(4)
            .enumerate()
            .map(|(index, spec)| CardLayout {
                card: layout.bounds(Element::Card(index)),
                name: layout.bounds(Element::Name(index)),
                prices: layout.bounds(Element::Prices(index)),
                platinum: layout.bounds(Element::Platinum(index)),
                vaulted: spec.vaulted.then(|| layout.bounds(Element::Vaulted(index))),
                ducats: layout.bounds(Element::Ducats(index)),
                ownership: layout.bounds(Element::Ownership(index)),
                components: layout.bounds(Element::Components(index)),
            })
            .collect(),
    })
}

fn relic_overlay_bounds(screen_width: u32, screen_height: u32) -> Rect {
    if screen_width == 0 || screen_height == 0 {
        return Rect {
            x: 0,
            y: 0,
            width: 0,
            height: 0,
        };
    }
    let from_1080 = f64::from(screen_height) / REFERENCE_HEIGHT;
    let content_width = (REFERENCE_WIDTH * from_1080).round().max(1.0) as u32;
    let content_width = content_width.min(screen_width);
    let width = content_width
        .saturating_add(WINDOW_CHROME_WIDTH)
        .min(screen_width);
    let offset = WINDOW_OFFSET.round() as u32;
    let x = ((screen_width - content_width) / 2)
        .saturating_sub(offset)
        .min(screen_width - width);
    let y = (REFERENCE_TOP * from_1080).round() as u32;
    let y = y.min(screen_height.saturating_sub(1));
    let height = WINDOW_HEIGHT.min(screen_height - y);
    Rect {
        x,
        y,
        width,
        height,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cards() -> [CardSpec; 4] {
        [CardSpec::default(); 4]
    }

    #[test]
    fn layout_matches_aleca_reference_at_1440p() {
        let layout = compute(2560, 1440, &cards()).unwrap();
        assert_eq!(
            layout.window,
            Rect {
                x: 598,
                y: 840,
                width: 1353,
                height: 355,
            }
        );
        assert_eq!(
            layout.shell,
            Rect {
                x: 613,
                y: 855,
                width: 1323,
                height: 325,
            }
        );
        assert_eq!(
            layout.holder,
            Rect {
                x: 615,
                y: 857,
                width: 1319,
                height: 270,
            }
        );
        assert_eq!(
            layout.cards,
            Rect {
                x: 622,
                y: 864,
                width: 1305,
                height: 256,
            }
        );
        assert_eq!(
            layout.footer,
            Rect {
                x: 615,
                y: 1127,
                width: 1319,
                height: 51,
            }
        );
        assert_eq!(layout.reward_cards[0].card.x, 622);
        assert_eq!(layout.reward_cards[1].card.x, 950);
        assert_eq!(layout.reward_cards[2].card.x, 1278);
        assert_eq!(layout.reward_cards[3].card.x, 1606);
        assert_eq!(
            layout.reward_cards[0].name,
            Rect {
                x: 628,
                y: 889,
                width: 309,
                height: 25,
            }
        );
        assert_eq!(
            layout.reward_cards[0].prices,
            Rect {
                x: 628,
                y: 940,
                width: 309,
                height: 30,
            }
        );
        assert_eq!(
            layout.reward_cards[0].platinum,
            Rect {
                x: 686,
                y: 941,
                width: 42,
                height: 28,
            }
        );
        assert_eq!(
            layout.reward_cards[0].ducats,
            Rect {
                x: 836,
                y: 940,
                width: 44,
                height: 30,
            }
        );
        assert_eq!(
            layout.reward_cards[0].ownership,
            Rect {
                x: 659,
                y: 988,
                width: 247,
                height: 27,
            }
        );
    }

    #[test]
    fn price_children_reflow_when_badges_exist() {
        let plain = compute(2560, 1440, &cards()).unwrap();
        let mut decorated = cards();
        decorated[0].vaulted = true;
        decorated[0].favorite = true;
        let decorated = compute(2560, 1440, &decorated).unwrap();
        assert!(decorated.reward_cards[0].platinum.x < plain.reward_cards[0].platinum.x);
        assert!(decorated.reward_cards[0].vaulted.is_some());
        assert!(decorated.reward_cards[0].ducats.x > plain.reward_cards[0].ducats.x);
    }

    #[test]
    fn platinum_box_grows_for_three_digit_price() {
        let mut specs = cards();
        specs[0].platinum_width = 68.0;
        let layout = compute(2560, 1440, &specs).unwrap();

        assert_eq!(layout.reward_cards[0].platinum.width, 68);
        assert!(layout.reward_cards[0].platinum.x < layout.reward_cards[0].ducats.x);
    }

    #[test]
    fn partial_squad_cards_are_centered_and_capped_at_quarter_width() {
        for count in 1..=3 {
            let specs = vec![CardSpec::default(); count];
            let layout = compute(2560, 1440, &specs).unwrap();
            let first = layout.reward_cards.first().unwrap().card;
            let last = layout.reward_cards.last().unwrap().card;
            assert_eq!(first.width, layout.cards.width / 4);
            assert!(
                (i64::from(first.x - layout.cards.x)
                    - i64::from(layout.cards.x + layout.cards.width - last.x - last.width))
                .abs()
                    <= 1
            );
        }
    }
}
