use clap::{Args, ValueEnum};
use std::ops::Range;
use std::path::PathBuf;
use std::time::Duration;
use wfcompanion::inspect::{memory, query};

#[derive(Args)]
pub struct Source {
    /// Read saved evidence instead of a live process.
    #[arg(long, conflicts_with = "pid")]
    capture: Option<PathBuf>,
    /// Select a Warframe PID; otherwise discover the running game.
    #[arg(long)]
    pid: Option<u32>,
}

impl Source {
    pub fn open(self) -> Result<memory::Source, String> {
        Ok(match self.capture {
            Some(path) => memory::Source::Capture(path),
            None => memory::Source::Live(match self.pid {
                Some(pid) => pid,
                None => super::support::game_pid()?,
            }),
        })
    }
}

#[derive(Args)]
#[group(id = "watch_options")]
pub struct Watch {
    /// Maximum duration in seconds (fractional values allowed, <=300).
    #[arg(long, default_value = "30", value_parser = duration)]
    pub seconds: Duration,
    /// Maximum records before stopping.
    #[arg(long, default_value_t = 1000)]
    pub limit: usize,
}

#[derive(Clone, Copy, ValueEnum)]
enum Scope {
    Research,
    Readable,
    Heap,
    Image,
}

#[derive(Args)]
pub struct Selection {
    /// Mapping scope: research includes private writable memory and the game image.
    #[arg(long, value_enum, default_value = "research")]
    scope: Scope,
    /// Restrict to START:LENGTH (decimal or 0x hex); repeat for multiple ranges.
    #[arg(long = "range", value_parser = range)]
    ranges: Vec<Range<u64>>,
}

impl Selection {
    pub fn query(&self) -> query::Selection {
        query::Selection {
            scope: match self.scope {
                Scope::Research => query::Scope::Research,
                Scope::Readable => query::Scope::Readable,
                Scope::Heap => query::Scope::Heap,
                Scope::Image => query::Scope::Image,
            },
            ranges: self.ranges.clone(),
        }
    }
}

#[derive(Args)]
pub struct Walk {
    #[command(flatten)]
    selection: Selection,
    /// Bytes inspected from each pointer target.
    #[arg(long, default_value_t = 512)]
    block_size: usize,
    #[arg(long, default_value_t = 16)]
    depth: u8,
    #[arg(long, default_value_t = 8192)]
    blocks: usize,
    /// Pointer-field stride; use 1 for packed structures.
    #[arg(long, default_value_t = 8)]
    stride: usize,
}

impl Walk {
    pub fn query(&self) -> query::WalkOptions {
        query::WalkOptions {
            selection: self.selection.query(),
            block_size: self.block_size,
            max_depth: self.depth,
            max_blocks: self.blocks,
            stride: self.stride,
        }
    }
}

pub fn number(value: &str) -> Result<u64, String> {
    if let Some(hex) = value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
    {
        u64::from_str_radix(hex, 16).map_err(|_| format!("invalid number: {value}"))
    } else {
        value
            .parse()
            .map_err(|_| format!("invalid number: {value}"))
    }
}

pub fn range(value: &str) -> Result<Range<u64>, String> {
    let (start, length) = value.split_once(':').ok_or("range requires START:LENGTH")?;
    target(number(start)?, number(length)?)
}

pub fn target(start: u64, length: u64) -> Result<Range<u64>, String> {
    let end = start
        .checked_add(length)
        .filter(|end| *end > start)
        .ok_or("empty or overflowing range")?;
    Ok(start..end)
}

#[derive(Clone)]
pub struct Hex(pub Vec<u8>);

pub fn hex(value: &str) -> Result<Hex, String> {
    let compact: String = value
        .chars()
        .filter(|c| !matches!(c, ' ' | ':' | '_' | '-'))
        .collect();
    let compact = compact
        .strip_prefix("0x")
        .or_else(|| compact.strip_prefix("0X"))
        .unwrap_or(&compact);
    if compact.is_empty()
        || !compact.len().is_multiple_of(2)
        || !compact.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err(format!("invalid hexadecimal byte sequence: {value}"));
    }
    compact
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).map_err(|e| e.to_string())
        })
        .collect::<Result<Vec<_>, _>>()
        .map(Hex)
}

pub fn split(value: &str) -> Result<char, String> {
    match value.to_ascii_uppercase().as_str() {
        "H" => Ok('H'),
        "B" => Ok('B'),
        "F" => Ok('F'),
        _ => Err("split must be H, B or F".into()),
    }
}

fn duration(value: &str) -> Result<Duration, String> {
    let seconds = value.parse::<f64>().map_err(|e| e.to_string())?;
    if !seconds.is_finite() || seconds <= 0.0 || seconds > 300.0 {
        return Err("seconds must be >0 and <=300".into());
    }
    Ok(Duration::from_secs_f64(seconds))
}
