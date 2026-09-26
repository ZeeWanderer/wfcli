use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::{
    ScriptInfo,
    analysis::*,
    corpus::{self, Snapshot},
    info,
    profile::Profile,
};

#[derive(Debug, Deserialize, Serialize)]
pub struct Manifest {
    pub schema: u8,
    pub features: BTreeMap<String, Feature>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct Feature {
    pub scripts: Vec<String>,
    #[serde(default)]
    pub native: Vec<String>,
    #[serde(default)]
    pub data: Vec<String>,
}

impl Manifest {
    pub fn builtin() -> Self {
        serde_json::from_str(include_str!("features.json")).expect("checked-in feature manifest")
    }

    pub fn load(path: &Path) -> Result<Self, String> {
        let value: Self = corpus::read_json(path)?;
        if value.schema != 1 {
            return Err("unsupported feature manifest schema".into());
        }
        Ok(value)
    }
}

#[derive(Debug, Serialize)]
pub struct Report {
    pub schema: u8,
    pub baseline: String,
    pub target: String,
    pub baseline_profile_sha256: String,
    pub target_profile_sha256: String,
    pub candidate_profiles: bool,
    pub capture_errors: BTreeMap<String, BTreeMap<String, String>>,
    pub summary: BTreeMap<String, usize>,
    pub scripts: BTreeMap<String, Change>,
    pub features: BTreeMap<String, Impact>,
}

#[derive(Debug, Serialize)]
pub struct Change {
    pub status: String,
    pub error: Option<String>,
    pub old_prototypes: Option<usize>,
    pub new_prototypes: Option<usize>,
    pub matched_prototypes: usize,
    pub bodies_matching_except_atoms: usize,
    pub prototype_matches: Vec<PrototypeMatch>,
    pub possible_dependencies: BTreeSet<String>,
}

#[derive(Debug, Serialize)]
pub struct PrototypeMatch {
    pub before: usize,
    pub after: usize,
    pub atoms_changed: bool,
}

impl Change {
    fn new(status: &str) -> Self {
        Self {
            status: status.into(),
            error: None,
            old_prototypes: None,
            new_prototypes: None,
            matched_prototypes: 0,
            bodies_matching_except_atoms: 0,
            prototype_matches: Vec::new(),
            possible_dependencies: BTreeSet::new(),
        }
    }

    fn review(&self) -> bool {
        !matches!(self.status.as_str(), "unchanged" | "opcode_encoding_only")
    }
}

#[derive(Debug, Serialize)]
pub struct Impact {
    pub review_required: bool,
    pub scripts: BTreeMap<String, String>,
    pub native_review: Vec<String>,
    pub data_not_tracked: Vec<String>,
}

pub fn compare(
    workspace: &Path,
    before: &Snapshot,
    after: &Snapshot,
    manifest: &Manifest,
) -> Report {
    let mut report = Report {
        schema: 1,
        baseline: before.name.clone(),
        target: after.name.clone(),
        baseline_profile_sha256: fingerprint(&json!(before.profile)),
        target_profile_sha256: fingerprint(&json!(after.profile)),
        candidate_profiles: before.profile.status != "reviewed"
            || after.profile.status != "reviewed",
        capture_errors: BTreeMap::new(),
        summary: BTreeMap::new(),
        scripts: BTreeMap::new(),
        features: BTreeMap::new(),
    };
    for snapshot in [before, after] {
        if !snapshot.errors.is_empty() {
            report
                .capture_errors
                .insert(snapshot.name.clone(), snapshot.errors.clone());
        }
    }
    let paths: BTreeSet<_> = before.scripts.keys().chain(after.scripts.keys()).collect();
    for path in paths {
        let result = compare_script(workspace, before, after, path);
        let change = result.unwrap_or_else(|error| {
            let mut c = Change::new("unsupported_or_corrupt");
            c.error = Some(error);
            c
        });
        *report.summary.entry(change.status.clone()).or_default() += 1;
        report.scripts.insert(path.clone(), change);
    }
    for (name, feature) in &manifest.features {
        let mut visited = BTreeSet::new();
        let mut pending = feature.scripts.clone();
        let mut scripts = BTreeMap::new();
        while let Some(path) = pending.pop() {
            if !visited.insert(path.clone()) {
                continue;
            }
            if let Some(change) = report.scripts.get(&path) {
                pending.extend(change.possible_dependencies.iter().cloned());
                if change.review() {
                    scripts.insert(path, change.status.clone());
                }
            } else {
                scripts.insert(path, "not_captured".into());
            }
        }
        let native_review = if before.profile.executable_sha256 != after.profile.executable_sha256 {
            feature.native.clone()
        } else {
            Vec::new()
        };
        let review_required = !scripts.is_empty()
            || !native_review.is_empty()
            || !feature.data.is_empty()
            || report.candidate_profiles
            || !report.capture_errors.is_empty();
        report.features.insert(
            name.clone(),
            Impact {
                review_required,
                scripts,
                native_review,
                data_not_tracked: feature.data.clone(),
            },
        );
    }
    report
}

fn compare_script(
    workspace: &Path,
    before: &Snapshot,
    after: &Snapshot,
    path: &str,
) -> Result<Change, String> {
    let old = before
        .scripts
        .get(path)
        .map(|_| {
            corpus::read_script(workspace, before, path)
                .and_then(|bytes| Ok((info(&bytes, &before.profile)?, bytes)))
        })
        .transpose()?;
    let new = after
        .scripts
        .get(path)
        .map(|_| {
            corpus::read_script(workspace, after, path)
                .and_then(|bytes| Ok((info(&bytes, &after.profile)?, bytes)))
        })
        .transpose()?;
    let mut change = match (&old, &new) {
        (Some((old_info, a)), Some((new_info, b))) => {
            compare_parsed(a, old_info, &before.profile, b, new_info, &after.profile)
                .unwrap_or_else(|error| {
                    let mut c = Change::new("unsupported_or_corrupt");
                    c.error = Some(error);
                    c
                })
        }
        (Some(_), None) => Change::new("not_in_target_snapshot"),
        (None, Some(_)) => Change::new("not_in_baseline_snapshot"),
        _ => unreachable!(),
    };
    for (script, _) in [&old, &new].into_iter().flatten() {
        change.possible_dependencies.extend(dependencies(script));
    }
    for (input, profile) in [(&old, &before.profile), (&new, &after.profile)] {
        if let Some((script, _)) = input {
            for proto in &script.prototypes {
                if let Err(error) = instructions(proto, profile) {
                    change.status = "unsupported_or_corrupt".into();
                    change.error = Some(error);
                    break;
                }
            }
        }
    }
    Ok(change)
}

fn compare_parsed(
    a: &[u8],
    old: &ScriptInfo,
    old_profile: &Profile,
    b: &[u8],
    new: &ScriptInfo,
    new_profile: &Profile,
) -> Result<Change, String> {
    let old_bodies = bodies(old, old_profile, false)?;
    let new_bodies = bodies(new, new_profile, false)?;
    let old_anonymous = bodies(old, old_profile, true)?;
    let new_anonymous = bodies(new, new_profile, true)?;
    let status = if old.main_prototype == new.main_prototype && old_bodies == new_bodies {
        if normalized_bytes(a, old, old_profile)? == normalized_bytes(b, new, new_profile)? {
            if a == b {
                "unchanged"
            } else {
                "opcode_encoding_only"
            }
        } else {
            "metadata_or_layout_changed_review"
        }
    } else if old.main_prototype == new.main_prototype && old_anonymous == new_anonymous {
        "atom_rebinding_review"
    } else {
        "code_or_constants_changed_review"
    };
    let mut change = Change::new(status);
    change.old_prototypes = Some(old.prototypes.len());
    change.new_prototypes = Some(new.prototypes.len());
    change.matched_prototypes = common_bodies(&old_bodies, &new_bodies);
    change.bodies_matching_except_atoms = common_bodies(&old_anonymous, &new_anonymous);
    for (old_index, body) in old_anonymous.iter().enumerate() {
        if old_anonymous.iter().filter(|other| *other == body).count() != 1 {
            continue;
        }
        let mut matches = new_anonymous
            .iter()
            .enumerate()
            .filter(|(_, other)| *other == body);
        if let Some((new_index, _)) = matches.next()
            && matches.next().is_none()
        {
            change.prototype_matches.push(PrototypeMatch {
                before: old_index,
                after: new_index,
                atoms_changed: old_bodies[old_index] != new_bodies[new_index],
            });
        }
    }
    Ok(change)
}

fn bodies(script: &ScriptInfo, profile: &Profile, hide_atoms: bool) -> Result<Vec<String>, String> {
    script
        .prototypes
        .iter()
        .map(|proto| projection(proto, script, profile, hide_atoms).map(|v| fingerprint(&v)))
        .collect()
}

fn common_bodies(old: &[String], new: &[String]) -> usize {
    let mut counts = BTreeMap::<&String, usize>::new();
    for body in old {
        *counts.entry(body).or_default() += 1;
    }
    new.iter()
        .filter(|body| match counts.get_mut(body) {
            Some(count) if *count > 0 => {
                *count -= 1;
                true
            }
            _ => false,
        })
        .count()
}

fn normalized_bytes(
    bytes: &[u8],
    script: &ScriptInfo,
    profile: &Profile,
) -> Result<Vec<u8>, String> {
    let mut bytes = bytes.to_vec();
    for proto in &script.prototypes {
        for (pc, op) in instructions(proto, profile)? {
            let word = (proto.words[pc] & operand_mask(op)) | u32::from(op.canonical);
            let start = proto.code_offset + pc * 4;
            bytes
                .get_mut(start..start + 4)
                .ok_or("invalid code offset")?
                .copy_from_slice(&word.to_le_bytes());
        }
    }
    Ok(bytes)
}

pub fn feature_manifest() -> Value {
    json!(Manifest::builtin())
}

#[derive(Default, Serialize)]
struct Occurrences {
    count: usize,
    examples: Vec<String>,
    name: Option<String>,
}

impl Occurrences {
    fn add(&mut self, count: usize, path: &str) {
        self.count += count;
        if self.examples.len() < 8 && !self.examples.iter().any(|p| p == path) {
            self.examples.push(path.into());
        }
    }
}

pub fn coverage(workspace: &Path, snapshot: &Snapshot) -> Value {
    let mut opcodes = BTreeMap::<String, Occurrences>::new();
    let mut atoms = BTreeMap::<String, Occurrences>::new();
    let mut incomplete = BTreeMap::new();
    for path in snapshot.scripts.keys() {
        let result = corpus::read_script(workspace, snapshot, path)
            .and_then(|bytes| info(&bytes, &snapshot.profile));
        match result {
            Ok(script) => {
                for op in &script.opcode_coverage {
                    let entry = opcodes.entry(format!("0x{:02x}", op.raw)).or_default();
                    entry.add(op.instructions, path);
                    entry.name = Some(op.name.clone());
                }
                for value in &script.atom_constants {
                    let entry = atoms.entry(value.hex.clone()).or_default();
                    entry.add(value.occurrences, path);
                    entry.name = snapshot.profile.symbols.get(&value.value).cloned();
                }
                let errors: Vec<_> = script
                    .prototypes
                    .iter()
                    .filter_map(|p| instructions(p, &snapshot.profile).err())
                    .collect();
                if !errors.is_empty() {
                    incomplete.insert(path.clone(), errors);
                }
            }
            Err(error) => {
                incomplete.insert(path.clone(), vec![error]);
            }
        }
    }
    json!({"schema": 1, "snapshot": snapshot.name, "executable_sha256": snapshot.profile.executable_sha256,
        "profile_sha256": fingerprint(&json!(snapshot.profile)), "scripts": snapshot.scripts.len(),
        "fully_decoded": snapshot.scripts.len() - incomplete.len(), "incomplete": incomplete,
        "capture_errors": snapshot.errors, "opcodes": opcodes, "atoms": atoms,
        "counting": "Known instruction boundaries only; stops at the first unknown opcode in each prototype. Atoms count constant-table entries."})
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inspect::luau::profile::Opcode;

    #[test]
    fn remapped_code_and_changed_literals_are_separate() {
        let mut p = Profile::unmapped("a".repeat(64));
        p.mapping.push(Opcode::new(100, 22).unwrap());
        let mut q = p.clone();
        q.mapping[0].raw = 200;
        let a = fixture(vec![100], vec![]);
        let b = fixture(vec![200], vec![]);
        let raw_a = 100u32.to_le_bytes();
        let raw_b = 200u32.to_le_bytes();
        assert_eq!(
            compare_parsed(&raw_a, &a, &p, &raw_b, &b, &q)
                .unwrap()
                .status,
            "opcode_encoding_only"
        );
        let mut c = b.clone();
        c.prototypes[0].words[0] |= 1 << 16;
        assert_eq!(
            compare_parsed(&raw_a, &a, &p, &raw_b, &c, &q)
                .unwrap()
                .status,
            "code_or_constants_changed_review"
        );
        q.mapping.clear();
        assert!(compare_parsed(&raw_a, &a, &p, &raw_b, &b, &q).is_err());
    }

    #[test]
    fn names_never_hide_changed_native_binding() {
        let mut p = Profile::unmapped("a".repeat(64));
        p.mapping.push(Opcode::new(100, 22).unwrap());
        let a = fixture(vec![100], vec![vec![1, 2, 0, 0, 0]]);
        let b = fixture(vec![100], vec![vec![1, 3, 0, 0, 0]]);
        p.symbols.insert(2, "sameLabel".into());
        p.symbols.insert(3, "sameLabel".into());
        assert_eq!(
            compare_parsed(&[], &a, &p, &[], &b, &p).unwrap().status,
            "atom_rebinding_review"
        );
    }

    #[test]
    fn feature_manifest_keeps_native_and_data_dependencies_explicit() {
        let manifest = Manifest::builtin();
        assert_eq!(manifest.schema, 1);
        let archimedea = &manifest.features["archimedea.weekly-loadout"];
        assert!(archimedea.native.iter().any(|name| name.contains("PCG")));
        assert!(!archimedea.data.is_empty());
    }
}
