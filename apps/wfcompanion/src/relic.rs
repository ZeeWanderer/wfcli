use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use image::imageops::{FilterType, crop_imm, resize};
use image::{DynamicImage, GenericImageView, GrayImage, Luma};
use serde::{Deserialize, Serialize};

use crate::UiEvent;
use crate::assets;
use crate::capture;
use crate::daemon::Outbound;
use crate::incident;

const REWARD_CAPTURE_DELAY: Duration = Duration::from_millis(650);
const REWARD_TRIGGER_DEDUPLICATION: Duration = Duration::from_secs(30);
const RETRY_DELAY: Duration = Duration::from_millis(1500);
const SUGGESTION_CAPTURE_DELAY: Duration = Duration::from_millis(750);
const SUGGESTION_RETRY_DELAY: Duration = Duration::from_millis(1000);
const SUGGESTION_TRIGGER_DEDUPLICATION: Duration = Duration::from_secs(2);
const SUGGESTION_REWARD_FALLBACK: Duration = Duration::from_secs(23);
const SUGGESTION_CLOSE_GUARD: Duration = Duration::from_millis(500);
const POST_REWARD_SUGGESTION_CLOSE_GUARD: Duration = Duration::from_millis(3500);
const REWARD_SCENE_LIFETIME: Duration = Duration::from_secs(15);
const ERROR_SCENE_LIFETIME: Duration = Duration::from_secs(8);
const REWARD_IDENTIFICATION_FAILED: &str = "could not identify relic reward names";
const TESSERACT_ARGUMENTS: &[&str] = &[
    "stdout",
    "--oem",
    "1",
    "--psm",
    "6",
    "-l",
    "eng",
    "-c",
    "preserve_interword_spaces=1",
];

#[derive(Debug)]
pub(crate) enum Trigger {
    Rewards,
    Suggestions,
    CloseSuggestions,
    DismissSuggestions,
    Screenshot(PathBuf),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum Scene {
    Reading,
    Rewards(Rewards),
    Suggestions(Suggestions),
    Error(String),
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct Rewards {
    pub(crate) items: Vec<Reward>,
    pub(crate) account: Account,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct Account {
    pub(crate) platinum: Option<u64>,
    pub(crate) ducats: Option<u64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct Reward {
    pub(crate) name: String,
    pub(crate) slug: Option<String>,
    pub(crate) game_ref: Option<String>,
    pub(crate) ducats: Option<u64>,
    pub(crate) lowest_sell: Option<u64>,
    pub(crate) highest_buy: Option<u64>,
    pub(crate) count_owned: u64,
    pub(crate) total_to_own: u64,
    pub(crate) crafted: Option<bool>,
    pub(crate) set_complete: Option<bool>,
    pub(crate) vaulted: bool,
    pub(crate) set_price: Option<u64>,
    pub(crate) asset: Option<Asset>,
    pub(crate) parts: Vec<SetPart>,
}

impl Reward {
    fn unresolved(name: String, slug: Option<String>, ducats: Option<u64>) -> Self {
        Self {
            name,
            slug,
            game_ref: None,
            ducats,
            lowest_sell: None,
            highest_buy: None,
            count_owned: 0,
            total_to_own: 1,
            crafted: None,
            set_complete: None,
            vaulted: false,
            set_price: None,
            asset: None,
            parts: Vec::new(),
        }
    }

    fn forma() -> Self {
        Self {
            name: "Forma Blueprint".to_owned(),
            slug: None,
            game_ref: Some("/Lotus/Types/Recipes/Components/FormaBlueprint".to_owned()),
            ducats: Some(0),
            lowest_sell: Some(2),
            highest_buy: None,
            count_owned: 0,
            total_to_own: 1,
            crafted: Some(true),
            set_complete: None,
            vaulted: false,
            set_price: None,
            asset: None,
            parts: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct SetPart {
    pub(crate) name: String,
    pub(crate) owned: u64,
    pub(crate) required: u64,
    pub(crate) current: bool,
    pub(crate) asset: Option<Asset>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct Asset {
    pub(crate) id: String,
    pub(crate) path: String,
    pub(crate) digest: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub(crate) struct Suggestions {
    pub(crate) trace_count: u64,
    pub(crate) items: Vec<Suggestion>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub(crate) struct Suggestion {
    pub(crate) name: String,
    pub(crate) amount_owned: u64,
    pub(crate) vaulted: bool,
    pub(crate) favorite: bool,
    pub(crate) expected_platinum: Option<u64>,
    pub(crate) expected_ducats: u64,
}

pub(crate) fn suggestion_fixture() -> Result<Scene, String> {
    serde_json::from_str(include_str!("../fixtures/relic-suggestions.json"))
        .map(Scene::Suggestions)
        .map_err(|error| format!("invalid relic suggestion fixture: {error}"))
}

pub(crate) fn diagnose(path: &Path) -> Result<serde_json::Value, String> {
    let image =
        image::open(path).map_err(|error| format!("could not read {}: {error}", path.display()))?;
    diagnose_image(
        &image,
        serde_json::Value::String(path.display().to_string()),
    )
}

pub(crate) fn diagnose_image(
    image: &DynamicImage,
    source: serde_json::Value,
) -> Result<serde_json::Value, String> {
    let detected_layouts = [Geometry::Normal, Geometry::Legacy]
        .into_iter()
        .map(|geometry| {
            serde_json::json!({
                "geometry": geometry_name(geometry),
                "players": detect_player_count(image, geometry),
            })
        })
        .collect::<Vec<_>>();
    let mut candidates = Vec::new();
    for geometry in [Geometry::Normal, Geometry::Legacy] {
        for count in (1..=4).rev() {
            let candidate = read_candidate(image, geometry, count)?;
            candidates.push(serde_json::json!({
                "geometry": geometry_name(geometry),
                "players": count,
                "labels": candidate.labels,
            }));
        }
    }
    Ok(serde_json::json!({
        "image": {
            "source": source,
            "width": image.width(),
            "height": image.height(),
        },
        "detected_layouts": detected_layouts,
        "candidates": candidates,
    }))
}

fn geometry_name(geometry: Geometry) -> &'static str {
    match geometry {
        Geometry::Normal => "normal",
        Geometry::Legacy => "legacy",
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Geometry {
    Normal,
    Legacy,
}

#[derive(Clone, Debug)]
struct Candidate {
    geometry: Geometry,
    count: usize,
    labels: Vec<String>,
}

#[derive(Clone, Debug)]
struct MarketMatch {
    name: String,
    slug: String,
    ducats: Option<u64>,
    distance: u64,
    confidence: f64,
}

struct Resolution {
    rewards: Vec<Reward>,
    complete: bool,
    score: f64,
    geometry: Geometry,
    count: usize,
}

pub(crate) fn spawn(
    triggers: mpsc::Receiver<Trigger>,
    daemon: mpsc::Sender<Outbound>,
    ui: mpsc::Sender<UiEvent>,
    stopping: Arc<AtomicBool>,
) {
    thread::spawn(move || {
        let mut last_reward_trigger: Option<Instant> = None;
        let mut last_suggestion_trigger: Option<Instant> = None;
        let mut last_suggestion_era: Option<String> = None;
        let mut last_suggestion_opened: Option<Instant> = None;
        let mut suggestion_after_reward = false;
        let mut suggestion_dismissed = false;
        let suggestion_generation = Arc::new(AtomicU64::new(0));
        while !stopping.load(Ordering::Relaxed) {
            let trigger = match triggers.recv_timeout(Duration::from_millis(200)) {
                Ok(trigger) => trigger,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => return,
            };
            let trigger_name = match &trigger {
                Trigger::Rewards => "rewards",
                Trigger::Suggestions => "suggestions",
                Trigger::CloseSuggestions => "close_suggestions",
                Trigger::DismissSuggestions => "dismiss_suggestions",
                Trigger::Screenshot(_) => "screenshot",
            };
            match trigger {
                Trigger::Suggestions => {
                    if suggestion_dismissed {
                        incident::info("relic.suggestion_dismissed", "current_context");
                        continue;
                    }
                    if reject_recent_trigger(
                        &mut last_suggestion_trigger,
                        SUGGESTION_TRIGGER_DEDUPLICATION,
                    ) {
                        incident::info("relic.suggestion_duplicate", "debug_output");
                        continue;
                    }
                    let reward_recent = last_reward_trigger.is_some_and(|seen| {
                        Instant::now().saturating_duration_since(seen) < SUGGESTION_REWARD_FALLBACK
                    });
                    let _ = ui.send(UiEvent::RelicSuggestionStart);
                    let opened = Instant::now();
                    let generation = suggestion_generation.fetch_add(1, Ordering::AcqRel) + 1;
                    match show_suggestions(
                        &daemon,
                        &ui,
                        reward_recent
                            .then_some(last_suggestion_era.as_deref())
                            .flatten(),
                    ) {
                        Ok(era) => {
                            last_suggestion_era = Some(era.clone());
                            last_suggestion_opened = Some(opened);
                            suggestion_after_reward = reward_recent;
                            spawn_suggestion_prices(
                                daemon.clone(),
                                ui.clone(),
                                stopping.clone(),
                                suggestion_generation.clone(),
                                generation,
                                era,
                            );
                        }
                        Err(error) => {
                            incident::warn("relic.suggestion_failed", &error);
                        }
                    }
                    continue;
                }
                Trigger::CloseSuggestions => {
                    suggestion_dismissed = false;
                    if let Some(opened) = last_suggestion_opened {
                        let elapsed = opened.elapsed();
                        if ignore_suggestion_close(suggestion_after_reward, elapsed) {
                            incident::info(
                                "relic.suggestion_close_ignored",
                                format!(
                                    "source=debug_output elapsed_ms={} after_reward={suggestion_after_reward}",
                                    elapsed.as_millis()
                                ),
                            );
                            continue;
                        }
                        incident::info(
                            "relic.suggestion_close",
                            format!(
                                "source=debug_output elapsed_ms={} after_reward={suggestion_after_reward}",
                                elapsed.as_millis()
                            ),
                        );
                    }
                    last_suggestion_opened = None;
                    suggestion_after_reward = false;
                    suggestion_generation.fetch_add(1, Ordering::AcqRel);
                    let _ = ui.send(UiEvent::RelicDismiss);
                    continue;
                }
                Trigger::DismissSuggestions => {
                    suggestion_dismissed = true;
                    last_suggestion_opened = None;
                    suggestion_after_reward = false;
                    suggestion_generation.fetch_add(1, Ordering::AcqRel);
                    incident::info("relic.suggestion_dismiss", "current_context");
                    continue;
                }
                Trigger::Rewards => {
                    suggestion_dismissed = false;
                }
                Trigger::Screenshot(_) => {}
            }
            suggestion_generation.fetch_add(1, Ordering::AcqRel);
            let live_capture = matches!(&trigger, Trigger::Rewards);
            if live_capture && reject_duplicate_reward_trigger(&mut last_reward_trigger) {
                incident::info("relic.trigger_duplicate", &trigger_name);
                continue;
            }
            incident::info("relic.trigger", &trigger_name);
            if live_capture {
                thread::sleep(REWARD_CAPTURE_DELAY);
            }
            let image = match capture_trigger(&trigger) {
                Ok(image) => image,
                Err(first_error) if live_capture => {
                    incident::warn("relic.capture_retry", &first_error);
                    thread::sleep(RETRY_DELAY);
                    match capture_trigger(&trigger) {
                        Ok(image) => image,
                        Err(error) => {
                            incident::error("relic.capture_failed", &error);
                            eprintln!("wfcompanion: relic capture failed: {error}");
                            send_scene(&ui, Scene::Error(error), None);
                            last_reward_trigger = None;
                            continue;
                        }
                    }
                }
                Err(error) => {
                    incident::error("relic.capture_failed", &error);
                    eprintln!("wfcompanion: relic capture failed: {error}");
                    send_scene(&ui, Scene::Error(error), None);
                    last_reward_trigger = None;
                    continue;
                }
            };
            let scene_deadline = live_capture.then(|| Instant::now() + REWARD_SCENE_LIFETIME);
            if live_capture {
                send_scene(&ui, Scene::Reading, scene_deadline);
            }
            incident::info(
                "relic.capture_ready",
                format!("{}x{} source={trigger_name}", image.width(), image.height()),
            );
            let started = Instant::now();
            let scanned = match scan_rewards(&image, &daemon) {
                Err(first_error) if live_capture => {
                    incident::warn("relic.ocr_retry", &first_error);
                    thread::sleep(RETRY_DELAY);
                    capture_trigger(&trigger).and_then(|retry| {
                        incident::info(
                            "relic.capture_ready",
                            format!("{}x{} source=retry", retry.width(), retry.height()),
                        );
                        scan_rewards(&retry, &daemon)
                    })
                }
                result => result,
            };
            match scanned {
                Ok(candidates) => {
                    let names = candidates
                        .iter()
                        .map(|reward| reward.name.as_str())
                        .collect::<Vec<_>>()
                        .join(" | ");
                    incident::info(
                        "relic.names_ready",
                        format!(
                            "elapsed_ms={} rewards={names}",
                            started.elapsed().as_millis()
                        ),
                    );
                    let (rewards, market) = match enrich_rewards(&daemon, candidates.clone()) {
                        Ok(rewards) => (rewards, "ready"),
                        Err(error) => {
                            incident::error("relic.context_failed", &error);
                            eprintln!("wfcompanion: relic context lookup failed: {error}");
                            (
                                Rewards {
                                    items: candidates,
                                    account: Account::default(),
                                },
                                "unavailable",
                            )
                        }
                    };
                    let names = rewards
                        .items
                        .iter()
                        .map(|reward| reward.name.as_str())
                        .collect::<Vec<_>>()
                        .join(" | ");
                    incident::info(
                        "relic.ready",
                        format!(
                            "elapsed_ms={} market={market} rewards={names}",
                            started.elapsed().as_millis()
                        ),
                    );
                    eprintln!(
                        "wfcompanion: relic reward scene ready in {} ms",
                        started.elapsed().as_millis()
                    );
                    send_scene(&ui, Scene::Rewards(rewards), scene_deadline);
                }
                Err(error) => {
                    incident::error("relic.ocr_failed", &error);
                    eprintln!("wfcompanion: relic OCR failed: {error}");
                    send_scene(&ui, Scene::Error(error), scene_deadline);
                    if live_capture {
                        last_reward_trigger = None;
                    }
                }
            }
        }
    });
}

fn send_scene(ui: &mpsc::Sender<UiEvent>, scene: Scene, deadline: Option<Instant>) {
    let deadline = deadline.or_else(|| {
        let lifetime = match &scene {
            Scene::Error(_) => Some(ERROR_SCENE_LIFETIME),
            Scene::Reading | Scene::Rewards(_) => Some(REWARD_SCENE_LIFETIME),
            Scene::Suggestions(_) => None,
        };
        lifetime.map(|lifetime| Instant::now() + lifetime)
    });
    let _ = ui.send(UiEvent::RelicScene { scene, deadline });
}

fn reject_duplicate_reward_trigger(last: &mut Option<Instant>) -> bool {
    reject_recent_trigger(last, REWARD_TRIGGER_DEDUPLICATION)
}

fn reject_recent_trigger(last: &mut Option<Instant>, duration: Duration) -> bool {
    let now = Instant::now();
    if last.is_some_and(|seen| now.saturating_duration_since(seen) < duration) {
        true
    } else {
        *last = Some(now);
        false
    }
}

fn ignore_suggestion_close(after_reward: bool, elapsed: Duration) -> bool {
    elapsed < SUGGESTION_CLOSE_GUARD
        || (after_reward && elapsed < POST_REWARD_SUGGESTION_CLOSE_GUARD)
}

fn capture_trigger(trigger: &Trigger) -> Result<DynamicImage, String> {
    match trigger {
        Trigger::Rewards => capture::relic_window(),
        Trigger::Screenshot(path) => {
            image::open(path).map_err(|error| format!("could not read {}: {error}", path.display()))
        }
        Trigger::Suggestions | Trigger::CloseSuggestions | Trigger::DismissSuggestions => {
            Err("trigger does not contain a reward capture".to_owned())
        }
    }
}

fn show_suggestions(
    daemon: &mpsc::Sender<Outbound>,
    ui: &mpsc::Sender<UiEvent>,
    fallback_era: Option<&str>,
) -> Result<String, String> {
    let started = Instant::now();
    thread::sleep(SUGGESTION_CAPTURE_DELAY);
    let (mut era, mut capture_ms, mut ocr_ms) = timed_suggestion_era();
    let mut retried = false;
    if let Err(first_error) = &era {
        incident::warn("relic.suggestion_ocr_retry", &first_error);
        thread::sleep(SUGGESTION_RETRY_DELAY);
        retried = true;
        let (retry, retry_capture_ms, retry_ocr_ms) = timed_suggestion_era();
        era = retry;
        capture_ms += retry_capture_ms;
        ocr_ms += retry_ocr_ms;
    }
    let era = match era {
        Ok(era) => era,
        Err(error) => fallback_era.map(str::to_owned).ok_or(error)?,
    };
    let daemon_started = Instant::now();
    let response = crate::daemon::relic_recommendations(daemon, era.clone(), false)?;
    let daemon_ms = daemon_started.elapsed().as_millis();
    let suggestions = parse_suggestions(&response)?;
    let priced = priced_suggestion_count(&suggestions);
    let total_ms = started.elapsed().as_millis();
    incident::info(
        "relic.suggestion_ready",
        format!(
            "era={era} relics={} priced={priced} total_ms={total_ms} capture_ms={capture_ms} ocr_ms={ocr_ms} daemon_ms={daemon_ms} retried={retried}",
            suggestions.items.len(),
        ),
    );
    send_scene(ui, Scene::Suggestions(suggestions), None);
    Ok(era)
}

fn timed_suggestion_era() -> (Result<String, String>, u128, u128) {
    let capture_started = Instant::now();
    let image = capture::relic_window();
    let capture_ms = capture_started.elapsed().as_millis();
    let image = match image {
        Ok(image) => image,
        Err(error) => return (Err(error), capture_ms, 0),
    };
    let ocr_started = Instant::now();
    let era = suggestion_era(&image);
    (era, capture_ms, ocr_started.elapsed().as_millis())
}

fn spawn_suggestion_prices(
    daemon: mpsc::Sender<Outbound>,
    ui: mpsc::Sender<UiEvent>,
    stopping: Arc<AtomicBool>,
    current_generation: Arc<AtomicU64>,
    generation: u64,
    era: String,
) {
    thread::spawn(move || {
        let result = crate::daemon::relic_recommendations(&daemon, era.clone(), true)
            .and_then(|response| parse_suggestions(&response));
        if stopping.load(Ordering::Relaxed)
            || current_generation.load(Ordering::Acquire) != generation
        {
            return;
        }
        match result {
            Ok(suggestions) => {
                let priced = priced_suggestion_count(&suggestions);
                incident::info(
                    "relic.suggestion_prices_ready",
                    format!(
                        "era={era} relics={} priced={priced}",
                        suggestions.items.len()
                    ),
                );
                send_scene(&ui, Scene::Suggestions(suggestions), None);
            }
            Err(error) => incident::warn("relic.suggestion_prices_failed", error),
        }
    });
}

fn parse_suggestions(response: &serde_json::Value) -> Result<Suggestions, String> {
    serde_json::from_value(
        response
            .get("data")
            .cloned()
            .ok_or_else(|| "daemon returned no relic recommendations".to_owned())?,
    )
    .map_err(|error| format!("daemon returned malformed relic recommendations: {error}"))
}

fn priced_suggestion_count(suggestions: &Suggestions) -> usize {
    suggestions
        .items
        .iter()
        .filter(|item| item.expected_platinum.is_some())
        .count()
}

fn suggestion_era(image: &DynamicImage) -> Result<String, String> {
    let x = image.width() * 25 / 1000;
    let y = image.height() * 65 / 1000;
    let width = (image.width() * 150 / 1000).min(image.width().saturating_sub(x));
    let height = (image.height() * 120 / 1000).min(image.height().saturating_sub(y));
    if width == 0 || height == 0 {
        return Err("relic suggestion crop is empty".to_owned());
    }
    let crop = crop_imm(image, x, y, width, height).to_image();
    parse_suggestion_era(&run_tesseract(preprocess(&crop))?)
        .ok_or_else(|| "could not identify relic era".to_owned())
}

fn parse_suggestion_era(label: &str) -> Option<String> {
    let normalized = label
        .chars()
        .filter(|character| !character.is_whitespace())
        .flat_map(char::to_lowercase)
        .collect::<String>();
    ["lith", "meso", "neo", "axi", "all"]
        .into_iter()
        .find(|era| normalized.contains(era))
        .map(str::to_owned)
}

fn scan_rewards(
    image: &DynamicImage,
    daemon: &mpsc::Sender<Outbound>,
) -> Result<Vec<Reward>, String> {
    let mut detected = Vec::new();
    for geometry in [Geometry::Normal, Geometry::Legacy] {
        if let Some(count) = detect_player_count(image, geometry) {
            detected.push(read_candidate(image, geometry, count)?);
        }
    }
    if !detected.is_empty() {
        match resolve_reward_candidates(daemon, detected) {
            Ok(detected_result) if detected_result.complete => {
                incident::info(
                    "relic.layout",
                    format!(
                        "geometry={} players={} path=border",
                        geometry_name(detected_result.geometry),
                        detected_result.count
                    ),
                );
                eprintln!(
                    "wfcompanion: relic OCR selected {:?} {}-player border path",
                    detected_result.geometry, detected_result.count
                );
                return Ok(detected_result.rewards);
            }
            Ok(_) => {}
            Err(error) if error == REWARD_IDENTIFICATION_FAILED => {}
            Err(error) => return Err(error),
        }
    }

    let fast = read_candidate(image, Geometry::Normal, 4)?;
    let fast_result = resolve_reward_candidates(daemon, vec![fast.clone()])?;
    if fast_result.complete {
        incident::info("relic.layout", "geometry=normal players=4 path=fast");
        eprintln!("wfcompanion: relic OCR selected Normal 4-player fast path");
        return Ok(fast_result.rewards);
    }

    let mut normal = vec![fast];
    for count in (1..=3).rev() {
        normal.push(read_candidate(image, Geometry::Normal, count)?);
    }
    let normal_result = resolve_reward_candidates(daemon, normal)?;
    if normal_result.complete {
        incident::info(
            "relic.layout",
            format!(
                "geometry={} players={}",
                geometry_name(normal_result.geometry),
                normal_result.count
            ),
        );
        eprintln!(
            "wfcompanion: relic OCR selected {:?} {}-player layout",
            normal_result.geometry, normal_result.count
        );
        return Ok(normal_result.rewards);
    }

    let mut legacy = Vec::with_capacity(4);
    for count in (1..=4).rev() {
        legacy.push(read_candidate(image, Geometry::Legacy, count)?);
    }
    let legacy_result = resolve_reward_candidates(daemon, legacy)?;
    let selected = if legacy_result.score > normal_result.score {
        legacy_result
    } else {
        normal_result
    };
    eprintln!(
        "wfcompanion: relic OCR selected {:?} {}-player layout",
        selected.geometry, selected.count
    );
    incident::info(
        "relic.layout",
        format!(
            "geometry={} players={}",
            geometry_name(selected.geometry),
            selected.count
        ),
    );
    Ok(selected.rewards)
}

fn resolve_reward_candidates(
    daemon: &mpsc::Sender<Outbound>,
    candidates: Vec<Candidate>,
) -> Result<Resolution, String> {
    let mut positions = Vec::new();
    let mut labels = Vec::new();
    let mut matches: Vec<Vec<Option<MarketMatch>>> = candidates
        .iter()
        .map(|candidate| vec![None; candidate.labels.len()])
        .collect();

    for (candidate_index, candidate) in candidates.iter().enumerate() {
        for (label_index, label) in candidate.labels.iter().enumerate() {
            if label.is_empty() || is_forma(label) {
                continue;
            }
            positions.push((candidate_index, label_index));
            labels.push(label.clone());
        }
    }

    if !labels.is_empty() {
        let response = crate::daemon::market_resolve(daemon, labels, 2)?;
        let resolutions = response
            .get("data")
            .and_then(|data| data.get("resolutions"))
            .and_then(serde_json::Value::as_array)
            .ok_or_else(|| "daemon returned malformed market resolution".to_owned())?;
        if resolutions.len() != positions.len() {
            return Err("daemon returned incomplete market resolution".to_owned());
        }
        for ((candidate_index, label_index), resolution) in positions.into_iter().zip(resolutions) {
            matches[candidate_index][label_index] = accepted_match(resolution);
        }
    }

    let (selected_index, selected_score) = candidates
        .iter()
        .enumerate()
        .map(|(index, candidate)| (index, candidate_score(candidate, &matches[index])))
        .max_by(|left, right| left.1.total_cmp(&right.1))
        .filter(|(_, score)| *score > 0.0)
        .ok_or_else(|| REWARD_IDENTIFICATION_FAILED.to_owned())?;
    let selected = &candidates[selected_index];
    let complete = selected
        .labels
        .iter()
        .zip(&matches[selected_index])
        .all(|(label, market_match)| is_forma(label) || market_match.is_some());

    let rewards: Vec<Reward> = selected
        .labels
        .iter()
        .zip(&matches[selected_index])
        .map(|(label, market_match)| {
            if is_forma(label) {
                Reward::forma()
            } else if let Some(market_match) = market_match {
                Reward::unresolved(
                    market_match.name.clone(),
                    Some(market_match.slug.clone()),
                    market_match.ducats,
                )
            } else {
                Reward::unresolved(
                    if label.is_empty() {
                        "Unrecognized reward".to_owned()
                    } else {
                        label.clone()
                    },
                    None,
                    None,
                )
            }
        })
        .collect();

    Ok(Resolution {
        rewards,
        complete,
        score: selected_score,
        geometry: selected.geometry,
        count: selected.count,
    })
}

fn enrich_rewards(
    daemon: &mpsc::Sender<Outbound>,
    mut rewards: Vec<Reward>,
) -> Result<Rewards, String> {
    let slugs: Vec<String> = rewards
        .iter()
        .filter_map(|reward| reward.slug.clone())
        .collect();
    if slugs.is_empty() {
        return Ok(Rewards {
            items: rewards,
            account: Account::default(),
        });
    }
    let response = crate::daemon::relic_context(daemon, slugs)?;
    let context: ContextReply = serde_json::from_value(
        response
            .get("data")
            .cloned()
            .ok_or_else(|| "daemon returned no relic context".to_owned())?,
    )
    .map_err(|error| format!("daemon returned malformed relic context: {error}"))?;
    let assets = resolve_assets(daemon, &context);
    for reward in &mut rewards {
        let Some(slug) = reward.slug.as_deref() else {
            continue;
        };
        let Some(item) = context.items.iter().find(|item| item.slug == slug) else {
            continue;
        };
        reward.name = item.name.clone();
        reward.game_ref.clone_from(&item.game_ref);
        reward.ducats = item.ducats.or(reward.ducats);
        reward.lowest_sell = item.lowest_sell;
        reward.highest_buy = item.highest_buy;
        reward.count_owned = item.count_owned;
        reward.total_to_own = item.total_to_own.max(1);
        reward.crafted = item.crafted;
        reward.set_complete = item.set_complete;
        reward.vaulted = item.vaulted;
        reward.set_price = item.set_price;
        reward.asset = item
            .asset
            .as_ref()
            .and_then(|spec| assets.get(&spec.id).cloned());
        reward.parts = item
            .parts
            .iter()
            .filter(|part| !part.set_root)
            .map(|part| SetPart {
                name: part.name.clone(),
                owned: part.owned,
                required: part.required.max(1),
                current: part.slug == slug,
                asset: part
                    .asset
                    .as_ref()
                    .and_then(|spec| assets.get(&spec.id).cloned()),
            })
            .collect();
    }
    Ok(Rewards {
        items: rewards,
        account: Account {
            platinum: context.account.platinum,
            ducats: context.account.ducats,
        },
    })
}

fn resolve_assets(
    daemon: &mpsc::Sender<Outbound>,
    context: &ContextReply,
) -> std::collections::BTreeMap<String, Asset> {
    let specs = context
        .items
        .iter()
        .flat_map(|item| {
            item.asset
                .iter()
                .chain(item.parts.iter().filter_map(|part| part.asset.as_ref()))
        })
        .fold(std::collections::BTreeMap::new(), |mut unique, spec| {
            unique
                .entry(spec.id.clone())
                .or_insert_with(|| spec.clone());
            unique
        });
    let mut resolved = std::collections::BTreeMap::new();
    let request = specs
        .into_values()
        .filter_map(|spec| {
            if let Some(asset) = embedded_asset(&spec) {
                resolved.insert(spec.id, asset);
                None
            } else {
                serde_json::to_value(spec).ok()
            }
        })
        .collect::<Vec<_>>();
    if request.is_empty() {
        return resolved;
    }
    let Ok(response) = crate::daemon::asset_resolve(daemon, request) else {
        return resolved;
    };
    resolved.extend(
        response
            .get("data")
            .and_then(|data| data.get("assets"))
            .and_then(serde_json::Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|descriptor| {
                if descriptor.get("ok").and_then(serde_json::Value::as_bool) != Some(true) {
                    return None;
                }
                Some((
                    descriptor.get("id")?.as_str()?.to_owned(),
                    Asset {
                        id: descriptor.get("id")?.as_str()?.to_owned(),
                        path: descriptor.get("path")?.as_str()?.to_owned(),
                        digest: descriptor.get("digest")?.as_str()?.to_owned(),
                    },
                ))
            })
            .collect::<std::collections::BTreeMap<_, _>>(),
    );
    resolved
}

fn embedded_asset(spec: &AssetSpec) -> Option<Asset> {
    assets::embedded_part(&spec.source, &spec.image_name).map(|embedded| Asset {
        id: spec.id.clone(),
        path: String::new(),
        digest: embedded.image.key.to_owned(),
    })
}

#[derive(Debug, Deserialize)]
struct ContextReply {
    #[serde(default)]
    items: Vec<ContextItem>,
    #[serde(default)]
    account: ContextAccount,
}

#[derive(Debug, Default, Deserialize)]
struct ContextAccount {
    platinum: Option<u64>,
    ducats: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct ContextItem {
    slug: String,
    name: String,
    game_ref: Option<String>,
    ducats: Option<u64>,
    lowest_sell: Option<u64>,
    highest_buy: Option<u64>,
    #[serde(default)]
    count_owned: u64,
    #[serde(default = "one")]
    total_to_own: u64,
    crafted: Option<bool>,
    set_complete: Option<bool>,
    #[serde(default)]
    vaulted: bool,
    set_price: Option<u64>,
    asset: Option<AssetSpec>,
    #[serde(default)]
    parts: Vec<ContextPart>,
}

#[derive(Debug, Deserialize)]
struct ContextPart {
    slug: String,
    name: String,
    #[serde(default)]
    owned: u64,
    #[serde(default = "one")]
    required: u64,
    #[serde(default)]
    set_root: bool,
    asset: Option<AssetSpec>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct AssetSpec {
    id: String,
    source: String,
    image_name: String,
}

fn one() -> u64 {
    1
}

fn accepted_match(resolution: &serde_json::Value) -> Option<MarketMatch> {
    let candidates = resolution.get("matches")?.as_array()?;
    let best = candidates.first()?;
    let distance = best.get("distance")?.as_u64()?;
    let confidence = best.get("confidence")?.as_f64()?;
    let second_confidence = candidates
        .get(1)
        .and_then(|candidate| candidate.get("confidence"))
        .and_then(serde_json::Value::as_f64)
        .unwrap_or(0.0);
    let unambiguous = distance == 0 || confidence - second_confidence >= 0.04;
    if (distance <= 2 || confidence >= 0.72) && unambiguous {
        Some(MarketMatch {
            name: best.get("name")?.as_str()?.to_owned(),
            slug: best.get("slug")?.as_str()?.to_owned(),
            ducats: best.get("ducats").and_then(serde_json::Value::as_u64),
            distance,
            confidence,
        })
    } else {
        None
    }
}

fn candidate_score(candidate: &Candidate, matches: &[Option<MarketMatch>]) -> f64 {
    let mut recognized = 0usize;
    let mut confidence = 0.0;
    let mut distance_penalty = 0.0;
    for (label, market_match) in candidate.labels.iter().zip(matches) {
        if is_forma(label) {
            recognized += 1;
            confidence += 1.0;
        } else if let Some(market_match) = market_match {
            recognized += 1;
            confidence += market_match.confidence;
            distance_penalty += market_match.distance as f64 * 0.01;
        }
    }
    if recognized == 0 {
        return 0.0;
    }
    let complete_bonus = if recognized == candidate.count {
        0.5
    } else {
        0.0
    };
    recognized as f64 * 2.0 + confidence / recognized as f64 + complete_bonus - distance_penalty
}

fn is_forma(label: &str) -> bool {
    let normalized = label
        .chars()
        .filter(|character| character.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect::<String>();
    normalized.contains("forma") || (normalized.contains("f0rma") && normalized.contains("blue"))
}

fn read_candidate(
    image: &DynamicImage,
    geometry: Geometry,
    count: usize,
) -> Result<Candidate, String> {
    let regions = reward_regions(image.width(), image.height(), geometry, count);
    let crops = regions
        .into_iter()
        .map(|(x, y, width, height)| crop_imm(image, x, y, width, height).to_image())
        .collect::<Vec<_>>();
    let labels = thread::scope(|scope| {
        let workers = crops
            .into_iter()
            .map(|crop| scope.spawn(move || run_tesseract(preprocess(&crop))))
            .collect::<Vec<_>>();
        workers
            .into_iter()
            .map(|worker| {
                worker
                    .join()
                    .map_err(|_| "tesseract worker panicked".to_owned())?
            })
            .collect::<Result<Vec<_>, String>>()
    })?;
    Ok(Candidate {
        geometry,
        count,
        labels,
    })
}

fn reward_regions(
    screen_width: u32,
    screen_height: u32,
    geometry: Geometry,
    count: usize,
) -> Vec<(u32, u32, u32, u32)> {
    let (top, bottom, width_ratio, separation_ratio) = match geometry {
        Geometry::Normal => (0.38, 0.427, 0.121, 0.0053),
        Geometry::Legacy => (0.4027, 0.437, 0.1005, 0.0052),
    };
    let reference_width = 1920.0 * screen_height as f64 / 1080.0;
    let mut card_width = (reference_width * width_ratio).round().max(1.0);
    let separation = (reference_width * separation_ratio).round();
    let mut y = (screen_height as f64 * top).round().max(0.0);
    let mut bottom_y = (screen_height as f64 * bottom).round().max(y + 1.0);
    if screen_width == 2560 && screen_height == 1600 {
        card_width = (card_width * 0.9).round().max(1.0);
        y = (y * 1.04).round();
        bottom_y = (bottom_y * 1.013).round().max(y + 1.0);
    }
    let total_width = card_width * count as f64 + separation * count.saturating_sub(1) as f64;
    let start_x = (screen_width as f64 - total_width) / 2.0;
    let height = bottom_y - y;

    (0..count)
        .filter_map(|index| {
            let x = start_x + index as f64 * (card_width + separation);
            clamp_region(
                screen_width,
                screen_height,
                x.round() as i64,
                y as i64,
                card_width as i64,
                height as i64,
            )
        })
        .collect()
}

fn detect_player_count(image: &DynamicImage, geometry: Geometry) -> Option<usize> {
    let counter = relic_counter_region(image.width(), image.height(), geometry)?;
    const PROBES: [(usize, [f64; 2]); 4] = [
        (4, [0.01, 0.91]),
        (3, [0.15, 0.78]),
        (2, [0.28, 0.665]),
        (1, [0.40, 0.535]),
    ];
    for (count, offsets) in PROBES {
        if offsets
            .into_iter()
            .filter_map(|offset| counter_probe(counter, offset))
            .any(|probe| has_reward_border(image, probe))
        {
            return Some(count);
        }
    }
    None
}

fn relic_counter_region(
    screen_width: u32,
    screen_height: u32,
    geometry: Geometry,
) -> Option<(u32, u32, u32, u32)> {
    let (counter_top, counter_bottom, width_ratio, separation_ratio) = match geometry {
        Geometry::Normal => (0.431, 0.458, 0.121, 0.0053),
        Geometry::Legacy => (0.441, 0.464, 0.1005, 0.0052),
    };
    let reference_width = 1920.0 * f64::from(screen_height) / 1080.0;
    let card_width = (reference_width * width_ratio) as i64;
    let separation = (reference_width * separation_ratio) as i64;
    let width = card_width * 4 + separation * 3;
    let x = i64::from(screen_width) / 2 - width / 2;
    let y = (f64::from(screen_height) * counter_top) as i64;
    let bottom = (f64::from(screen_height) * counter_bottom) as i64;
    let height = ((bottom - y) as f64 * 0.9) as i64;
    clamp_region(screen_width, screen_height, x, y, width, height)
}

fn counter_probe(counter: (u32, u32, u32, u32), offset: f64) -> Option<(u32, u32, u32, u32)> {
    let (x, y, width, height) = counter;
    let probe_x = x.saturating_add((f64::from(width) * offset) as u32);
    let probe_width = (f64::from(width) * 0.08) as u32;
    (probe_width > 0 && probe_x < x + width).then_some((
        probe_x,
        y,
        probe_width.min(x + width - probe_x),
        height,
    ))
}

fn has_reward_border(image: &DynamicImage, region: (u32, u32, u32, u32)) -> bool {
    let (x, y, width, height) = region;
    if width < 12 || height < 3 {
        return false;
    }
    let middle = y + height / 2;
    let start = x + width / 6;
    let end = x + width * 5 / 6;
    let mut previous = image.get_pixel(start, middle);
    let mut horizontal = 0_u32;
    for sample_x in start..end {
        let pixel = image.get_pixel(sample_x, middle);
        if color_distance(previous.0, pixel.0) >= 45.0 {
            break;
        }
        previous = pixel;
        horizontal += 1;
    }
    if horizontal as f64 / (f64::from(width) * 0.6) < 0.9 {
        return false;
    }

    let mut runs = Vec::with_capacity(width as usize);
    for sample_x in x..x + width {
        let mut previous = image.get_pixel(sample_x, middle);
        let mut run = 0_u32;
        for sample_y in (y..=middle).rev() {
            let pixel = image.get_pixel(sample_x, sample_y);
            if color_distance(previous.0, pixel.0) > 32.0 {
                break;
            }
            previous = pixel;
            run += 1;
        }
        for sample_y in middle + 1..y + height {
            let pixel = image.get_pixel(sample_x, sample_y);
            if color_distance(previous.0, pixel.0) > 32.0 {
                break;
            }
            previous = pixel;
            run += 1;
        }
        runs.push(f64::from(run));
    }

    if runs.iter().filter(|run| **run <= 1.0).count() > runs.len() / 3 {
        return false;
    }
    let average = runs.iter().sum::<f64>() / runs.len() as f64;
    let normalized_average = average / f64::from(height);
    if !(0.05..=0.27).contains(&normalized_average) {
        return false;
    }
    let mut sorted = runs.clone();
    sorted.sort_by(|left, right| right.total_cmp(left));
    let variance = sorted
        .iter()
        .skip(3)
        .map(|run| (run - average).powi(2))
        .sum::<f64>()
        / sorted.len().saturating_sub(3).max(1) as f64;
    5.0 * variance.sqrt() / f64::from(height) <= 0.36
}

fn color_distance(left: [u8; 4], right: [u8; 4]) -> f64 {
    let red = f64::from(left[0]) - f64::from(right[0]);
    let green = f64::from(left[1]) - f64::from(right[1]);
    let blue = f64::from(left[2]) - f64::from(right[2]);
    (red * red + green * green + blue * blue).sqrt()
}

fn clamp_region(
    screen_width: u32,
    screen_height: u32,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
) -> Option<(u32, u32, u32, u32)> {
    let left = x.clamp(0, i64::from(screen_width));
    let top = y.clamp(0, i64::from(screen_height));
    let right = (x + width).clamp(0, i64::from(screen_width));
    let bottom = (y + height).clamp(0, i64::from(screen_height));
    (right > left && bottom > top).then_some((
        left as u32,
        top as u32,
        (right - left) as u32,
        (bottom - top) as u32,
    ))
}

fn preprocess(source: &image::RgbaImage) -> GrayImage {
    let enlarged = resize(
        source,
        source.width().saturating_mul(3),
        source.height().saturating_mul(3),
        FilterType::Lanczos3,
    );
    let border = 12;
    let mut output = GrayImage::from_pixel(
        enlarged.width() + border * 2,
        enlarged.height() + border * 2,
        Luma([255]),
    );
    for (x, y, pixel) in enlarged.enumerate_pixels() {
        let [red, green, blue, _] = pixel.0;
        let luma = (u16::from(red) * 54 + u16::from(green) * 183 + u16::from(blue) * 19) / 256;
        output.put_pixel(
            x + border,
            y + border,
            Luma([if luma >= 135 { 0 } else { 255 }]),
        );
    }
    output
}

fn run_tesseract(image: GrayImage) -> Result<String, String> {
    let path = capture::temporary_png("ocr")?;
    image
        .save(&path)
        .map_err(|error| format!("could not write OCR image: {error}"))?;
    let tesseract = crate::external::resolve(
        "WFCOMPANION_TESSERACT",
        "tesseract",
        option_env!("WFCOMPANION_BUILD_TESSERACT"),
        &[
            PathBuf::from("/home/linuxbrew/.linuxbrew/bin/tesseract"),
            PathBuf::from("/usr/local/bin/tesseract"),
            PathBuf::from("/usr/bin/tesseract"),
        ],
    );
    let output = Command::new(tesseract)
        .arg(&path)
        .args(TESSERACT_ARGUMENTS)
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("could not run tesseract: {error}"));
    let _ = fs::remove_file(path);
    let output = output?;
    if !output.status.success() {
        let message = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        return Err(if message.is_empty() {
            format!("tesseract exited with {}", output.status)
        } else {
            format!("tesseract: {message}")
        });
    }
    Ok(clean_label(&String::from_utf8_lossy(&output.stdout)))
}

fn clean_label(label: &str) -> String {
    let cleaned: String = label
        .chars()
        .map(|character| match character {
            '|' | '~' | '"' | '=' | '?' | '!' | '\\' | '/' | '1'..='9' | '.' => ' ',
            _ => character,
        })
        .collect();
    let lines: Vec<String> = cleaned
        .lines()
        .map(|line| {
            line.split_whitespace()
                .filter_map(clean_token)
                .collect::<Vec<_>>()
                .join(" ")
        })
        .filter(|line| !line.is_empty())
        .collect();
    let has_substantial_line = lines.iter().any(|line| {
        line.chars()
            .filter(|character| character.is_alphanumeric())
            .count()
            >= 6
    });
    lines
        .into_iter()
        .filter(|line| {
            !has_substantial_line
                || line
                    .chars()
                    .filter(|character| character.is_alphanumeric())
                    .count()
                    > 2
        })
        .collect::<Vec<_>>()
        .join(" ")
        .trim_matches(|character: char| !character.is_alphanumeric())
        .to_owned()
}

fn clean_token(token: &str) -> Option<String> {
    let trimmed =
        token.trim_matches(|character: char| !character.is_alphanumeric() && character != '&');
    if trimmed.is_empty() || matches!(trimmed, "F" | "FF" | "L" | "LL") {
        return None;
    }
    let fixed = if trimmed.eq_ignore_ascii_case("Fanq") {
        "Fang"
    } else {
        trimmed
    };
    let alphanumeric = fixed
        .chars()
        .filter(|character| character.is_alphanumeric())
        .count();
    (alphanumeric > 2 || fixed.eq_ignore_ascii_case("bo") || fixed == "&").then(|| fixed.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suppresses_delayed_fallback_trigger_for_same_reward() {
        let mut last = Some(Instant::now() - Duration::from_secs(12));
        assert!(reject_duplicate_reward_trigger(&mut last));
        last = Some(Instant::now() - Duration::from_secs(31));
        assert!(!reject_duplicate_reward_trigger(&mut last));
    }

    #[test]
    fn suggestion_close_guards_match_aleca() {
        assert!(ignore_suggestion_close(false, Duration::from_millis(499)));
        assert!(!ignore_suggestion_close(false, Duration::from_millis(500)));
        assert!(ignore_suggestion_close(true, Duration::from_millis(3499)));
        assert!(!ignore_suggestion_close(true, Duration::from_millis(3500)));
    }

    #[test]
    fn suggestion_scene_has_no_deadline() {
        let (sender, receiver) = mpsc::channel();
        send_scene(
            &sender,
            Scene::Suggestions(Suggestions {
                trace_count: 0,
                items: Vec::new(),
            }),
            None,
        );
        let UiEvent::RelicScene { deadline, .. } = receiver.recv().unwrap() else {
            panic!("expected relic scene");
        };
        assert_eq!(deadline, None);
    }

    #[test]
    fn parses_relic_era_from_noisy_ocr() {
        assert_eq!(
            parse_suggestion_era("SELECT A RELIC\nA X I ERA"),
            Some("axi".to_owned())
        );
        assert_eq!(
            parse_suggestion_era("SELECT A RELIC\nALL ERA"),
            Some("all".to_owned())
        );
        assert_eq!(parse_suggestion_era("REQUIEM ERA"), None);
        assert_eq!(parse_suggestion_era("Void Fissure"), None);
    }

    #[test]
    fn detects_eras_from_1440p_selection_fixtures() {
        for (filename, expected) in [
            ("relic_selection_lith_2560x1440.jpg", "lith"),
            ("relic_selection_meso_2560x1440.jpg", "meso"),
            ("relic_selection_neo_2560x1440.jpg", "neo"),
            ("relic_selection_axi_2560x1440.jpg", "axi"),
            ("relic_selection_all_2560x1440.jpg", "all"),
        ] {
            let path = Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("tests")
                .join("fixtures")
                .join(filename);
            let image = image::open(&path)
                .unwrap_or_else(|error| panic!("could not open {}: {error}", path.display()));
            assert_eq!(
                suggestion_era(&image).as_deref(),
                Ok(expected),
                "fixture {filename}"
            );
        }
    }

    #[test]
    fn forma_uses_overlay_value_without_market_listing() {
        let forma = Reward::forma();
        assert_eq!(forma.lowest_sell, Some(2));
        assert_eq!(forma.ducats, Some(0));
        assert_eq!(forma.crafted, Some(true));
        assert_eq!(forma.slug, None);
    }

    #[test]
    fn counts_only_priced_relic_suggestions() {
        let suggestions = Suggestions {
            trace_count: 0,
            items: vec![
                Suggestion {
                    name: "Lith A1".to_owned(),
                    amount_owned: 1,
                    vaulted: false,
                    favorite: false,
                    expected_platinum: Some(12),
                    expected_ducats: 20,
                },
                Suggestion {
                    name: "Lith B1".to_owned(),
                    amount_owned: 1,
                    vaulted: false,
                    favorite: false,
                    expected_platinum: None,
                    expected_ducats: 15,
                },
            ],
        };

        assert_eq!(priced_suggestion_count(&suggestions), 1);
    }

    #[test]
    fn embedded_part_asset_bypasses_disk_cache() {
        for embedded in assets::EMBEDDED_PART_ASSETS {
            let spec = AssetSpec {
                id: "market:part".to_owned(),
                source: "market".to_owned(),
                image_name: embedded.id.to_owned(),
            };
            let asset = embedded_asset(&spec).unwrap();
            assert!(asset.path.is_empty());
            assert_eq!(asset.digest, embedded.image.key);
        }

        let wrong_source = AssetSpec {
            id: "wfcd:part".to_owned(),
            source: "wfcd".to_owned(),
            image_name: assets::EMBEDDED_PART_ASSETS[0].id.to_owned(),
        };
        assert!(embedded_asset(&wrong_source).is_none());
    }

    #[test]
    fn normal_four_player_regions_are_centered() {
        let regions = reward_regions(1920, 1080, Geometry::Normal, 4);
        assert_eq!(regions.len(), 4);
        assert_eq!(regions[0].1, 410);
        assert_eq!(regions[0].3, 51);
        let left = regions[0].0;
        let right = regions[3].0 + regions[3].2;
        assert!((i64::from(left) - i64::from(1920 - right)).abs() <= 1);
    }

    #[test]
    fn geometry_stays_inside_narrow_screen() {
        for region in reward_regions(1280, 1024, Geometry::Normal, 4) {
            assert!(region.0 + region.2 <= 1280);
            assert!(region.1 + region.3 <= 1024);
        }
    }

    #[test]
    fn applies_alecaframe_2560_by_1600_geometry_correction() {
        let regions = reward_regions(2560, 1600, Geometry::Normal, 4);
        assert_eq!(regions.len(), 4);
        assert_eq!(regions[0].1, 632);
        assert_eq!(regions[0].2, 310);
        assert_eq!(regions[0].3, 60);
    }

    #[test]
    fn cleans_multiline_ocr_output() {
        assert_eq!(
            clean_label("  [Saryn Prime\nChassis]  \n"),
            "Saryn Prime Chassis"
        );
    }

    #[test]
    fn removes_short_artifact_line_above_reward() {
        assert_eq!(
            clean_label("KA\nDual Zoren Prime Handle\n"),
            "Dual Zoren Prime Handle"
        );
    }

    #[test]
    fn removes_known_ocr_artifacts_without_losing_valid_short_names() {
        assert_eq!(clean_label("1 F | Bo Prime Handle!"), "Bo Prime Handle");
        assert_eq!(clean_label("Fanq Prime Blade"), "Fang Prime Blade");
        assert_eq!(
            clean_label("Cobra & Crane Prime Blade"),
            "Cobra & Crane Prime Blade"
        );
    }

    #[test]
    fn accepts_close_unambiguous_market_match() {
        let resolution = serde_json::json!({
            "matches": [
                {"name": "Saryn Prime Chassis Blueprint", "slug": "saryn_prime_chassis_blueprint", "ducats": 100, "distance": 1, "confidence": 0.9667},
                {"name": "Saryn Prime Systems Blueprint", "slug": "saryn_prime_systems_blueprint", "distance": 8, "confidence": 0.7333}
            ]
        });
        let matched = accepted_match(&resolution).unwrap();
        assert_eq!(matched.slug, "saryn_prime_chassis_blueprint");
        assert_eq!(matched.ducats, Some(100));
    }

    #[test]
    fn rejects_ambiguous_market_match() {
        let resolution = serde_json::json!({
            "matches": [
                {"name": "Thing A", "slug": "thing_a", "distance": 3, "confidence": 0.75},
                {"name": "Thing B", "slug": "thing_b", "distance": 3, "confidence": 0.74}
            ]
        });
        assert!(accepted_match(&resolution).is_none());
    }

    #[test]
    fn layout_score_rewards_multiple_recognized_cards() {
        let one = Candidate {
            geometry: Geometry::Normal,
            count: 1,
            labels: vec!["Saryn Prime Chassis".to_owned()],
        };
        let four = Candidate {
            geometry: Geometry::Normal,
            count: 4,
            labels: vec![
                "a".to_owned(),
                "b".to_owned(),
                "c".to_owned(),
                String::new(),
            ],
        };
        let matched = |name: &str| {
            Some(MarketMatch {
                name: name.to_owned(),
                slug: name.to_owned(),
                ducats: None,
                distance: 1,
                confidence: 0.9,
            })
        };
        assert!(
            candidate_score(&four, &[matched("a"), matched("b"), matched("c"), None])
                > candidate_score(&one, &[matched("saryn")])
        );
    }

    #[test]
    fn recognizes_non_tradable_forma() {
        assert!(is_forma("Forma Blueprint"));
        assert!(is_forma("F0rma Blueprnt"));
        assert!(!is_forma("Saryn Prime Blueprint"));
    }

    #[test]
    fn tesseract_uses_lstm_only_engine() {
        assert!(
            TESSERACT_ARGUMENTS
                .windows(2)
                .any(|pair| pair == ["--oem", "1"])
        );
    }

    #[test]
    fn reward_fixtures_detect_player_count_at_native_resolution() {
        for (name, expected) in [
            ("relic_rewards_1p_2560x1440.jpg", 1),
            ("relic_rewards_2p_2560x1440.jpg", 2),
            ("relic_rewards_3p_2560x1440.jpg", 3),
            ("relic_rewards_4p_2560x1440.jpg", 4),
        ] {
            let path = Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures")
                .join(name);
            let image = image::open(path).unwrap();
            assert_eq!((image.width(), image.height()), (2560, 1440));
            assert_eq!(
                detect_player_count(&image, Geometry::Normal),
                Some(expected)
            );
            assert_eq!(
                reward_regions(2560, 1440, Geometry::Normal, expected).len(),
                expected
            );
        }
    }
}
