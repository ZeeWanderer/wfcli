use taffy::TaffyError;
use taffy::geometry::Rect as TaffyRect;
use taffy::prelude::*;

const REFERENCE_HEIGHT: f64 = 1080.0;
const REFERENCE_WIDTH: f64 = 1000.0;
const REFERENCE_TOP: f64 = 630.0;
const PANEL_HEIGHT: u32 = 295;
const WINDOW_OFFSET: f64 = 15.0;
const AD_WIDTH: u32 = 420;
const AD_HEIGHT: u32 = 60;

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
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct RelicCardSpec {
    pub(crate) platinum_width: f32,
    pub(crate) ducats_width: f32,
    pub(crate) vaulted: bool,
    pub(crate) favorite: bool,
}

impl Default for RelicCardSpec {
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
pub(crate) struct RelicCardLayout {
    pub(crate) card: Rect,
    pub(crate) name: Rect,
    pub(crate) prices: Rect,
    pub(crate) platinum: Rect,
    pub(crate) vaulted: Option<Rect>,
    pub(crate) ducats: Rect,
    pub(crate) ownership: Rect,
    pub(crate) components: Rect,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RelicLayout {
    pub(crate) window: Rect,
    pub(crate) shell: Rect,
    pub(crate) holder: Rect,
    pub(crate) cards: Rect,
    pub(crate) footer: Rect,
    pub(crate) sidebar: Rect,
    pub(crate) reward_cards: Vec<RelicCardLayout>,
}

impl RelicLayout {
    pub(crate) fn scaled(mut self, scale: u32) -> Self {
        self.window = self.window.scaled(scale);
        self.shell = self.shell.scaled(scale);
        self.holder = self.holder.scaled(scale);
        self.cards = self.cards.scaled(scale);
        self.footer = self.footer.scaled(scale);
        self.sidebar = self.sidebar.scaled(scale);
        for card in &mut self.reward_cards {
            card.card = card.card.scaled(scale);
            card.name = card.name.scaled(scale);
            card.prices = card.prices.scaled(scale);
            card.platinum = card.platinum.scaled(scale);
            card.ducats = card.ducats.scaled(scale);
            card.ownership = card.ownership.scaled(scale);
            card.components = card.components.scaled(scale);
        }
        self
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RelicSuggestionLayout {
    pub(crate) shell: Rect,
    pub(crate) header: Rect,
    pub(crate) close: Rect,
    pub(crate) grid: Rect,
    pub(crate) cards: Vec<Rect>,
    pub(crate) footer: Rect,
}

impl RelicSuggestionLayout {
    pub(crate) fn scaled(mut self, scale: u32) -> Self {
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

struct CardNodes {
    card: NodeId,
    name: NodeId,
    prices: NodeId,
    platinum: NodeId,
    vaulted: Option<NodeId>,
    ducats: NodeId,
    ownership: NodeId,
    components: NodeId,
}

pub(crate) fn relic_layout(
    screen_width: u32,
    screen_height: u32,
    card_specs: &[RelicCardSpec],
) -> Result<RelicLayout, String> {
    let window = relic_overlay_bounds(screen_width, screen_height);
    let mut taffy: TaffyTree<()> = TaffyTree::new();
    taffy.disable_rounding();

    let mut card_nodes = Vec::with_capacity(card_specs.len());
    for spec in card_specs.iter().take(4) {
        let name = taffy
            .new_leaf(Style {
                size: Size {
                    width: percent(1.0_f32),
                    height: length(24.85_f32),
                },
                align_self: Some(AlignSelf::CENTER),
                grid_row: line(1),
                grid_column: span(2),
                ..Default::default()
            })
            .map_err(layout_error)?;

        let platinum = taffy
            .new_leaf(Style {
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
            })
            .map_err(layout_error)?;
        let mut price_children = vec![platinum];
        let vaulted = if spec.vaulted {
            Some(
                taffy
                    .new_leaf(Style {
                        size: Size {
                            width: length(36.0_f32),
                            height: length(30.0_f32),
                        },
                        ..Default::default()
                    })
                    .map_err(layout_error)?,
            )
        } else {
            None
        };
        price_children.extend(vaulted);
        if spec.favorite {
            price_children.push(
                taffy
                    .new_leaf(Style {
                        size: Size {
                            width: length(27.0_f32),
                            height: length(27.0_f32),
                        },
                        ..Default::default()
                    })
                    .map_err(layout_error)?,
            );
        }
        let ducats = taffy
            .new_leaf(Style {
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
            })
            .map_err(layout_error)?;
        price_children.push(ducats);
        let prices = taffy
            .new_with_children(
                Style {
                    display: Display::Flex,
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
            )
            .map_err(layout_error)?;

        let ownership = taffy
            .new_leaf(Style {
                size: Size {
                    width: percent(0.8_f32),
                    height: length(27.0_f32),
                },
                align_self: Some(AlignSelf::CENTER),
                justify_self: Some(JustifySelf::CENTER),
                grid_row: line(3),
                grid_column: span(2),
                ..Default::default()
            })
            .map_err(layout_error)?;
        let components = taffy
            .new_leaf(Style {
                size: Size {
                    width: percent(1.0_f32),
                    height: percent(1.0_f32),
                },
                align_self: Some(AlignSelf::CENTER),
                grid_row: line(4),
                grid_column: span(2),
                ..Default::default()
            })
            .map_err(layout_error)?;

        let card = taffy
            .new_with_children(
                Style {
                    display: Display::Grid,
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
            )
            .map_err(layout_error)?;
        card_nodes.push(CardNodes {
            card,
            name,
            prices,
            platinum,
            vaulted,
            ducats,
            ownership,
            components,
        });
    }

    let holder = taffy
        .new_with_children(
            Style {
                display: Display::Flex,
                flex_direction: FlexDirection::Row,
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
            &card_nodes
                .iter()
                .map(|nodes| nodes.card)
                .collect::<Vec<_>>(),
        )
        .map_err(layout_error)?;
    let footer = taffy
        .new_leaf(Style {
            size: Size {
                width: percent(1.0_f32),
                height: percent(0.16_f32),
            },
            flex_shrink: 0.0,
            ..Default::default()
        })
        .map_err(layout_error)?;
    let relic_part = taffy
        .new_with_children(
            Style {
                display: Display::Flex,
                flex_direction: FlexDirection::Column,
                flex_grow: 1.0,
                min_size: Size {
                    width: length(0.0_f32),
                    height: length(0.0_f32),
                },
                ..Default::default()
            },
            &[holder, footer],
        )
        .map_err(layout_error)?;
    let sidebar = taffy
        .new_leaf(Style {
            size: Size {
                width: length(400.0_f32),
                height: percent(1.0_f32),
            },
            min_size: Size {
                width: length(400.0_f32),
                height: length(300.0_f32),
            },
            flex_shrink: 0.0,
            ..Default::default()
        })
        .map_err(layout_error)?;
    let shell = taffy
        .new_with_children(
            Style {
                display: Display::Flex,
                flex_direction: FlexDirection::Row,
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
            &[relic_part, sidebar],
        )
        .map_err(layout_error)?;
    let root = taffy
        .new_with_children(
            Style {
                display: Display::Flex,
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
        )
        .map_err(layout_error)?;

    taffy
        .compute_layout(
            root,
            Size {
                width: AvailableSpace::Definite(window.width as f32),
                height: AvailableSpace::Definite(window.height as f32),
            },
        )
        .map_err(layout_error)?;

    let origin = (window.x as f32, window.y as f32);
    let shell_origin = child_origin(&taffy, shell, origin)?;
    let relic_origin = child_origin(&taffy, relic_part, shell_origin)?;
    let holder_origin = child_origin(&taffy, holder, relic_origin)?;
    let holder_rect = node_rect(&taffy, holder, relic_origin)?;
    let cards = Rect {
        x: holder_rect.x + 7,
        y: holder_rect.y + 7,
        width: holder_rect.width.saturating_sub(14),
        height: holder_rect.height.saturating_sub(14),
    };
    let mut reward_cards = Vec::with_capacity(card_nodes.len());
    for nodes in card_nodes {
        let card_origin = child_origin(&taffy, nodes.card, holder_origin)?;
        let prices_origin = child_origin(&taffy, nodes.prices, card_origin)?;
        reward_cards.push(RelicCardLayout {
            card: node_rect(&taffy, nodes.card, holder_origin)?,
            name: node_rect(&taffy, nodes.name, card_origin)?,
            prices: node_rect(&taffy, nodes.prices, card_origin)?,
            platinum: node_rect(&taffy, nodes.platinum, prices_origin)?,
            vaulted: nodes
                .vaulted
                .map(|node| node_rect(&taffy, node, prices_origin))
                .transpose()?,
            ducats: node_rect(&taffy, nodes.ducats, prices_origin)?,
            ownership: node_rect(&taffy, nodes.ownership, card_origin)?,
            components: node_rect(&taffy, nodes.components, card_origin)?,
        });
    }

    Ok(RelicLayout {
        window,
        shell: node_rect(&taffy, shell, origin)?,
        holder: holder_rect,
        cards,
        footer: node_rect(&taffy, footer, relic_origin)?,
        sidebar: node_rect(&taffy, sidebar, shell_origin)?,
        reward_cards,
    })
}

pub(crate) fn relic_suggestion_layout(
    screen_width: u32,
    screen_height: u32,
    item_count: usize,
) -> RelicSuggestionLayout {
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
    RelicSuggestionLayout {
        shell,
        header,
        close,
        grid,
        cards,
        footer,
    }
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
    let width = content_width.saturating_add(AD_WIDTH).min(screen_width);
    let offset = WINDOW_OFFSET.round() as u32;
    let x = ((screen_width - content_width) / 2)
        .saturating_sub(offset)
        .min(screen_width - width);
    let y = (REFERENCE_TOP * from_1080).round() as u32;
    let y = y.min(screen_height.saturating_sub(1));
    let height = PANEL_HEIGHT
        .saturating_add(AD_HEIGHT)
        .min(screen_height - y);
    Rect {
        x,
        y,
        width,
        height,
    }
}

fn child_origin(
    taffy: &TaffyTree<()>,
    node: NodeId,
    parent: (f32, f32),
) -> Result<(f32, f32), String> {
    let layout = taffy.layout(node).map_err(layout_error)?;
    Ok((parent.0 + layout.location.x, parent.1 + layout.location.y))
}

fn node_rect(taffy: &TaffyTree<()>, node: NodeId, parent: (f32, f32)) -> Result<Rect, String> {
    let layout = taffy.layout(node).map_err(layout_error)?;
    Ok(Rect {
        x: (parent.0 + layout.location.x).round().max(0.0) as u32,
        y: (parent.1 + layout.location.y).round().max(0.0) as u32,
        width: layout.size.width.round().max(0.0) as u32,
        height: layout.size.height.round().max(0.0) as u32,
    })
}

fn layout_error(error: TaffyError) -> String {
    format!("relic layout failed: {error}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cards() -> [RelicCardSpec; 4] {
        [RelicCardSpec::default(); 4]
    }

    #[test]
    fn layout_matches_aleca_reference_at_1440p() {
        let layout = relic_layout(2560, 1440, &cards()).unwrap();
        assert_eq!(
            layout.window,
            Rect {
                x: 598,
                y: 840,
                width: 1753,
                height: 355,
            }
        );
        assert_eq!(
            layout.shell,
            Rect {
                x: 613,
                y: 855,
                width: 1723,
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
        assert_eq!(
            layout.sidebar,
            Rect {
                x: 1934,
                y: 857,
                width: 400,
                height: 321,
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
        let plain = relic_layout(2560, 1440, &cards()).unwrap();
        let mut decorated = cards();
        decorated[0].vaulted = true;
        decorated[0].favorite = true;
        let decorated = relic_layout(2560, 1440, &decorated).unwrap();
        assert!(decorated.reward_cards[0].platinum.x < plain.reward_cards[0].platinum.x);
        assert!(decorated.reward_cards[0].vaulted.is_some());
        assert!(decorated.reward_cards[0].ducats.x > plain.reward_cards[0].ducats.x);
    }

    #[test]
    fn platinum_box_grows_for_three_digit_price() {
        let mut specs = cards();
        specs[0].platinum_width = 68.0;
        let layout = relic_layout(2560, 1440, &specs).unwrap();

        assert_eq!(layout.reward_cards[0].platinum.width, 68);
        assert!(layout.reward_cards[0].platinum.x < layout.reward_cards[0].ducats.x);
    }

    #[test]
    fn partial_squad_cards_are_centered_and_capped_at_quarter_width() {
        for count in 1..=3 {
            let specs = vec![RelicCardSpec::default(); count];
            let layout = relic_layout(2560, 1440, &specs).unwrap();
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

    #[test]
    fn suggestion_layout_matches_aleca_reference() {
        let layout = relic_suggestion_layout(2560, 1440, 4);
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
