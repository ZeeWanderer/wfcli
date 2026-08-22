use std::fs::{self, File};
use std::io;
use std::os::unix::fs::FileExt;

use iced_x86::{Decoder, DecoderOptions, Instruction, Mnemonic, OpKind, Register};
use memchr::memchr;

const MAX_PAYLOAD_SIZE: usize = 0x4e2000;
const RESPONSE_READ_SIZE: usize = 0x9e2000 - 1;
const RESPONSE_READ_CHUNK_SIZE: usize = 256 * 1024;
const SCAN_CHUNK_SIZE: usize = 1024 * 1024;
const HTTP_MANAGER_PATTERN: &[u8] = &[
    0x48, 0x00, 0x00, 0x48, 0x8b, 0x0d, 0x00, 0x00, 0x00, 0x00, 0x48, 0x85, 0x00, 0x74, 0x00, 0x48,
    0x8b, 0xd3, 0xe8,
];
const HTTP_MANAGER_MASK: &[u8] = &[
    0xff, 0x00, 0x00, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0x00, 0xff, 0x00, 0xff,
    0xff, 0xff, 0xff,
];
const ALTERNATE_RESPONSE_PATTERN: &[u8] = &[
    0x4c, 0x8d, 0x87, 0x00, 0x00, 0x00, 0x00, 0xb2, 0x01, 0x48, 0x8b, 0xcf, 0xe8,
];
const ALTERNATE_RESPONSE_MASK: &[u8] = &[
    0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ExecutableRegion {
    start: u64,
    end: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ResponsePath {
    queue_table: u64,
    item_base: u64,
    body: u64,
    alternate: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct Sources {
    manager_global: u64,
    response: ResponsePath,
}

pub(super) struct PollState {
    direct: ChangeState,
    indirect: ChangeState,
    alternate: ChangeState,
    scratch: Vec<u8>,
}

impl Default for PollState {
    fn default() -> Self {
        Self {
            direct: ChangeState::default(),
            indirect: ChangeState::default(),
            alternate: ChangeState::default(),
            scratch: vec![0; RESPONSE_READ_SIZE],
        }
    }
}

#[derive(Default)]
struct ChangeState {
    address: Option<u64>,
    payload: Vec<u8>,
}

impl Sources {
    pub(super) fn discover(mem: &File, game_pid: u32) -> Result<Self, String> {
        let executable = executable_region(game_pid)?;
        let anchor = scan_masked(mem, executable, HTTP_MANAGER_PATTERN, HTTP_MANAGER_MASK)?;
        let manager_displacement = read_i32(mem, anchor + 6)
            .map_err(|error| format!("could not read Warframe HTTP manager anchor: {error}"))?;
        let manager_global = (anchor + 10).wrapping_add_signed(i64::from(manager_displacement));

        let call_displacement = read_i32(mem, anchor + 19)
            .map_err(|error| format!("could not read Warframe HTTP handler call: {error}"))?;
        let handler = (anchor + 23).wrapping_add_signed(i64::from(call_displacement));
        if handler < executable.start || handler >= executable.end {
            return Err("Warframe HTTP handler is outside the executable mapping".to_owned());
        }
        let handler_size = usize::try_from((executable.end - handler).min(0x500)).unwrap();
        let mut handler_code = vec![0_u8; handler_size];
        read_exact_at(mem, handler, &mut handler_code)
            .map_err(|error| format!("could not read Warframe HTTP handler: {error}"))?;
        let (queue_table, item_base, body) = derive_response_layout(&handler_code, handler)?;

        let alternate_anchor = scan_masked(
            mem,
            executable,
            ALTERNATE_RESPONSE_PATTERN,
            ALTERNATE_RESPONSE_MASK,
        )?;
        let alternate = i64::from(
            read_i32(mem, alternate_anchor + 3)
                .map_err(|error| format!("could not read alternate response offset: {error}"))?,
        );

        Ok(Self {
            manager_global,
            response: ResponsePath {
                queue_table,
                item_base,
                body,
                alternate,
            },
        })
    }

    pub(super) fn manager_global(&self) -> u64 {
        self.manager_global
    }

    pub(super) fn response_offsets(&self) -> (u64, u64, u64, i64) {
        (
            self.response.queue_table,
            self.response.item_base,
            self.response.body,
            self.response.alternate,
        )
    }

    pub(super) fn persistent_payloads(
        &self,
        mem: &File,
        state: &mut PollState,
    ) -> Vec<(&'static str, Vec<u8>)> {
        let Ok(manager) = read_u64(mem, self.manager_global).and_then(non_null) else {
            return Vec::new();
        };
        let mut payloads = Vec::with_capacity(3);
        if let Ok(body) = self.primary_body(mem, manager) {
            let Some(payload) = changed_c_string(mem, body, &mut state.direct, &mut state.scratch)
            else {
                return payloads;
            };
            payloads.push(("direct", payload));
            if let Ok(indirect) = read_u64(mem, body).and_then(non_null)
                && let Some(payload) =
                    changed_c_string(mem, indirect, &mut state.indirect, &mut state.scratch)
            {
                payloads.push(("indirect", payload));
            } else {
                return payloads;
            }
        } else {
            return payloads;
        }
        if let Ok((data, length)) = self.alternate_response(mem, manager)
            && let Some(payload) = changed_buffer(mem, data, length, &mut state.alternate)
        {
            payloads.push(("alternate", payload));
        }
        payloads
    }

    fn primary_body(&self, mem: &File, manager: u64) -> io::Result<u64> {
        let table_slot = manager
            .checked_add(self.response.queue_table)
            .ok_or_else(|| invalid_pointer("Warframe HTTP table"))?;
        let table = non_null(read_u64(mem, table_slot)?)?;
        let bucket = non_null(read_u64(mem, table)?)?;
        let item = non_null(read_u64(mem, bucket)?)?;
        let body_slot = item
            .checked_add(self.response.item_base)
            .and_then(|address| address.checked_add(self.response.body))
            .ok_or_else(|| invalid_pointer("Warframe response"))?;
        non_null(read_u64(mem, body_slot)?)
    }

    fn alternate_response(&self, mem: &File, manager: u64) -> io::Result<(u64, usize)> {
        let level_one_slot = manager
            .checked_add(0x38)
            .ok_or_else(|| invalid_pointer("Warframe alternate response"))?;
        let level_one = non_null(read_u64(mem, level_one_slot)?)?;
        let base_slot = level_one
            .checked_add(0x10)
            .ok_or_else(|| invalid_pointer("Warframe alternate response"))?;
        let base = non_null(read_u64(mem, base_slot)?)?;
        let slot = base.wrapping_add_signed(self.response.alternate);
        let data = non_null(read_u64(mem, slot)?)?;
        let length_slot = slot
            .checked_add(8)
            .ok_or_else(|| invalid_pointer("Warframe alternate response length"))?;
        let length = usize::from(read_u16(mem, length_slot)?);
        if length == 0 || length > MAX_PAYLOAD_SIZE {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid alternate Warframe response length",
            ));
        }
        Ok((data, length))
    }
}

fn changed_c_string(
    mem: &File,
    address: u64,
    state: &mut ChangeState,
    scratch: &mut [u8],
) -> Option<Vec<u8>> {
    if state.address == Some(address)
        && !state.payload.is_empty()
        && !c_string_changed(mem, address, state, scratch)
    {
        return None;
    }
    let payload = read_c_string(mem, address, scratch).ok()?;
    if state.address == Some(address) && state.payload == payload {
        return None;
    }
    remember_payload(state, address, &payload);
    Some(payload)
}

fn changed_buffer(
    mem: &File,
    address: u64,
    length: usize,
    state: &mut ChangeState,
) -> Option<Vec<u8>> {
    let mut payload = vec![0_u8; length];
    read_exact_at(mem, address, &mut payload).ok()?;
    if state.address == Some(address) && state.payload == payload {
        return None;
    }
    remember_payload(state, address, &payload);
    Some(payload)
}

fn remember_payload(state: &mut ChangeState, address: u64, payload: &[u8]) {
    state.address = Some(address);
    state.payload.clear();
    state.payload.extend_from_slice(payload);
}

fn c_string_changed(mem: &File, address: u64, state: &ChangeState, scratch: &mut [u8]) -> bool {
    let Some(length) = state.payload.len().checked_add(1) else {
        return true;
    };
    let Some(current) = scratch.get_mut(..length) else {
        return true;
    };
    if read_exact_at(mem, address, current).is_err() {
        return true;
    }
    current.last() != Some(&0) || current[..state.payload.len()] != state.payload
}

#[derive(Clone, Copy)]
struct MemoryLoad {
    position: usize,
    base: Register,
    destination: Register,
    displacement: u64,
}

fn derive_response_layout(code: &[u8], ip: u64) -> Result<(u64, u64, u64), String> {
    let instructions: Vec<_> = Decoder::with_ip(64, code, ip, DecoderOptions::NONE)
        .into_iter()
        .collect();
    let loads: Vec<_> = instructions
        .iter()
        .enumerate()
        .filter_map(|(position, instruction)| memory_load(position, instruction))
        .collect();

    for low in &loads {
        if low.displacement < 0x20 || low.displacement > 0x1000 {
            continue;
        }
        let fields = [
            low.displacement,
            low.displacement + 8,
            low.displacement + 16,
            low.displacement + 24,
        ];
        let matching: Vec<_> = loads
            .iter()
            .filter(|load| {
                load.base == low.base
                    && load.position.abs_diff(low.position) <= 16
                    && fields.contains(&load.displacement)
            })
            .collect();
        if matching.len() != fields.len() {
            continue;
        }
        let first = matching.iter().map(|load| load.position).min().unwrap();
        let last = matching.iter().map(|load| load.position).max().unwrap();
        if last - first > 16 {
            continue;
        }

        let mut dereferences = 0;
        let mut item_ready = None;
        for (position, instruction) in instructions
            .iter()
            .enumerate()
            .skip(low.position + 1)
            .take(32)
        {
            if instruction.mnemonic() == Mnemonic::Mov
                && instruction.op0_kind() == OpKind::Register
                && instruction.op0_register() == low.destination
                && instruction.op1_kind() == OpKind::Memory
                && instruction.memory_base() == low.destination
                && instruction.memory_index() != Register::None
                && instruction.memory_index_scale() == 8
            {
                dereferences += 1;
                if dereferences == 2 {
                    item_ready = Some(position);
                    break;
                }
            }
        }
        let Some(item_ready) = item_ready else {
            continue;
        };
        let Some((item_view_position, item_view, item_base)) = instructions
            .iter()
            .enumerate()
            .skip(item_ready + 1)
            .take(96)
            .find_map(|(position, instruction)| {
                lea_from(instruction, low.destination)
                    .map(|(destination, displacement)| (position, destination, displacement))
            })
        else {
            continue;
        };
        let Some(body) = body_offset_before_movzx(
            &instructions[item_view_position + 1..instructions.len().min(item_view_position + 161)],
            item_view,
        ) else {
            continue;
        };
        if item_base > 0x1000 || body > 0x1000 || item_base + body > 0x1000 {
            continue;
        }
        return Ok((low.displacement, item_base, body));
    }
    Err("could not derive Warframe persistent response layout".to_owned())
}

fn body_offset_before_movzx(instructions: &[Instruction], item_view: Register) -> Option<u64> {
    let mut latest_lea = None;
    for instruction in instructions {
        if let Some((_, displacement)) = lea_from(instruction, item_view) {
            latest_lea = Some(displacement);
        }
        if instruction.mnemonic() == Mnemonic::Movzx
            && instruction.op1_kind() == OpKind::Memory
            && instruction.memory_base() == item_view
        {
            return latest_lea;
        }
    }
    None
}

fn memory_load(position: usize, instruction: &Instruction) -> Option<MemoryLoad> {
    (instruction.mnemonic() == Mnemonic::Mov
        && instruction.op0_kind() == OpKind::Register
        && instruction.op1_kind() == OpKind::Memory
        && instruction.memory_base() != Register::None
        && instruction.memory_base() != Register::RIP
        && instruction.memory_index() == Register::None)
        .then(|| MemoryLoad {
            position,
            base: instruction.memory_base(),
            destination: instruction.op0_register(),
            displacement: instruction.memory_displacement64(),
        })
}

fn lea_from(instruction: &Instruction, base: Register) -> Option<(Register, u64)> {
    let displacement = instruction.memory_displacement64();
    (instruction.mnemonic() == Mnemonic::Lea
        && instruction.op0_kind() == OpKind::Register
        && instruction.op1_kind() == OpKind::Memory
        && instruction.memory_base() == base
        && instruction.memory_index() == Register::None
        && displacement > 0
        && displacement <= 0x1000)
        .then(|| (instruction.op0_register(), displacement))
}

fn executable_region(game_pid: u32) -> Result<ExecutableRegion, String> {
    let maps = fs::read_to_string(format!("/proc/{game_pid}/maps"))
        .map_err(|error| format!("could not read Warframe memory map: {error}"))?;
    find_executable_region(&maps).ok_or_else(|| "Warframe executable mapping not found".to_owned())
}

fn find_executable_region(maps: &str) -> Option<ExecutableRegion> {
    let mut image_start = None;
    for line in maps.lines() {
        let mut fields = line.split_whitespace();
        let range = fields.next().unwrap_or_default();
        let permissions = fields.next().unwrap_or_default();
        let path = fields.nth(3).unwrap_or_default();
        let Some((start, end)) = parse_range(range) else {
            continue;
        };
        if path.ends_with("/Warframe.x64.exe") {
            image_start = Some(start);
        }
        if permissions.contains('x')
            && image_start.is_some_and(|image| start >= image && start - image < 0x4000_0000)
        {
            return Some(ExecutableRegion { start, end });
        }
    }
    None
}

fn parse_range(range: &str) -> Option<(u64, u64)> {
    let (start, end) = range.split_once('-')?;
    Some((
        u64::from_str_radix(start, 16).ok()?,
        u64::from_str_radix(end, 16).ok()?,
    ))
}

fn scan_masked(
    mem: &File,
    region: ExecutableRegion,
    pattern: &[u8],
    mask: &[u8],
) -> Result<u64, String> {
    let mut offset = region.start;
    let mut tail = Vec::new();
    let mut chunk = vec![0_u8; SCAN_CHUNK_SIZE];
    while offset < region.end {
        let wanted = usize::try_from((region.end - offset).min(SCAN_CHUNK_SIZE as u64)).unwrap();
        let read = mem
            .read_at(&mut chunk[..wanted], offset)
            .map_err(|error| format!("could not scan Warframe executable: {error}"))?;
        if read == 0 {
            break;
        }
        let mut searchable = Vec::with_capacity(tail.len() + read);
        searchable.extend_from_slice(&tail);
        searchable.extend_from_slice(&chunk[..read]);
        if let Some(index) = find_masked(&searchable, pattern, mask) {
            return Ok(offset.saturating_sub(tail.len() as u64) + index as u64);
        }
        let overlap = pattern.len() - 1;
        tail.clear();
        tail.extend_from_slice(&chunk[read.saturating_sub(overlap)..read]);
        offset += read as u64;
    }
    Err("Warframe GEP signature not found".to_owned())
}

fn find_masked(haystack: &[u8], pattern: &[u8], mask: &[u8]) -> Option<usize> {
    haystack.windows(pattern.len()).position(|window| {
        window
            .iter()
            .zip(pattern)
            .zip(mask)
            .all(|((&byte, &expected), &significant)| byte & significant == expected & significant)
    })
}

fn read_c_string(mem: &File, address: u64, scratch: &mut [u8]) -> io::Result<Vec<u8>> {
    let mut offset = 0;
    while offset < scratch.len() {
        let end = scratch.len().min(offset + RESPONSE_READ_CHUNK_SIZE);
        let chunk_address = address
            .checked_add(offset as u64)
            .ok_or_else(|| invalid_pointer("Warframe HTTP response"))?;
        read_exact_at(mem, chunk_address, &mut scratch[offset..end])?;
        if let Some(relative_end) = memchr(0, &scratch[offset..end]) {
            let payload_end = offset + relative_end;
            if payload_end == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "empty Warframe HTTP response",
                ));
            }
            return Ok(scratch[..payload_end].to_vec());
        }
        offset = end;
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidData,
        "unterminated Warframe HTTP response",
    ))
}

fn non_null(address: u64) -> io::Result<u64> {
    if address == 0 {
        Err(io::Error::new(
            io::ErrorKind::NotFound,
            "null Warframe pointer",
        ))
    } else {
        Ok(address)
    }
}

fn invalid_pointer(name: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!("invalid {name} pointer"),
    )
}

fn read_exact_at(mem: &File, address: u64, buffer: &mut [u8]) -> io::Result<()> {
    let mut read = 0;
    while read < buffer.len() {
        let read_address = address
            .checked_add(read as u64)
            .ok_or_else(|| invalid_pointer("process-memory read"))?;
        let count = mem.read_at(&mut buffer[read..], read_address)?;
        if count == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "short process-memory read",
            ));
        }
        read += count;
    }
    Ok(())
}

fn read_u16(mem: &File, address: u64) -> io::Result<u16> {
    let mut bytes = [0_u8; 2];
    read_exact_at(mem, address, &mut bytes)?;
    Ok(u16::from_le_bytes(bytes))
}

fn read_i32(mem: &File, address: u64) -> io::Result<i32> {
    let mut bytes = [0_u8; 4];
    read_exact_at(mem, address, &mut bytes)?;
    Ok(i32::from_le_bytes(bytes))
}

fn read_u64(mem: &File, address: u64) -> io::Result<u64> {
    let mut bytes = [0_u8; 8];
    read_exact_at(mem, address, &mut bytes)?;
    Ok(u64::from_le_bytes(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::OpenOptions;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn derives_persistent_response_layout() {
        let code = [
            0x4d, 0x8b, 0x8d, 0xb0, 0x00, 0x00, 0x00, // mov r9,[r13+b0]
            0x4d, 0x8b, 0x85, 0xa8, 0x00, 0x00, 0x00, // mov r8,[r13+a8]
            0x49, 0x8b, 0x85, 0xa0, 0x00, 0x00, 0x00, // mov rax,[r13+a0]
            0x49, 0x8b, 0xbd, 0x98, 0x00, 0x00, 0x00, // mov rdi,[r13+98]
            0x48, 0x8b, 0x3c, 0xcf, // mov rdi,[rdi+rcx*8]
            0x48, 0x8b, 0x3c, 0xc7, // mov rdi,[rdi+rax*8]
            0x4c, 0x8d, 0x67, 0x18, // lea r12,[rdi+18]
            0x49, 0x8d, 0x4c, 0x24, 0x50, // lea rcx,[r12+50]
            0x4d, 0x8d, 0x44, 0x24, 0x38, // lea r8,[r12+38]
            0x41, 0x0f, 0xb6, 0x54, 0x24, 0x18, // movzx edx,byte [r12+18]
        ];
        assert_eq!(
            derive_response_layout(&code, 0x140000000).unwrap(),
            (0x98, 0x18, 0x38)
        );
    }

    #[test]
    fn reads_primary_persistent_response() {
        let mut bytes = vec![0_u8; 0x1000];
        put_u64(&mut bytes, 0x20, 0x100);
        put_u64(&mut bytes, 0x198, 0x300);
        put_u64(&mut bytes, 0x300, 0x400);
        put_u64(&mut bytes, 0x400, 0x500);
        put_u64(&mut bytes, 0x550, 0x700);
        let payload = b"{\"LastInventorySync\":\"live\"}\0";
        bytes[0x700..0x700 + payload.len()].copy_from_slice(payload);
        let path = temp_file(&bytes);
        let mem = File::open(&path).unwrap();
        let sources = Sources {
            manager_global: 0x20,
            response: ResponsePath {
                queue_table: 0x98,
                item_base: 0x18,
                body: 0x38,
                alternate: 0,
            },
        };
        let mut state = PollState {
            scratch: vec![0; payload.len()],
            ..PollState::default()
        };
        let payloads = sources.persistent_payloads(&mem, &mut state);
        assert_eq!(payloads[0].0, "direct");
        assert_eq!(payloads[0].1, b"{\"LastInventorySync\":\"live\"}");
        assert!(sources.persistent_payloads(&mem, &mut state).is_empty());
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn detects_reused_inventory_buffer_changes() {
        let mut payload = br#"{"padding":""#.to_vec();
        payload.extend(std::iter::repeat_n(b'a', 256));
        payload.extend_from_slice(br#"","LastInventorySync":"one"}"#);
        payload.push(0);
        let path = temp_file(&payload);
        let mem = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        let mut state = ChangeState::default();
        let mut scratch = vec![0; payload.len()];

        assert_eq!(
            changed_c_string(&mem, 0, &mut state, &mut scratch),
            Some(payload[..payload.len() - 1].to_vec())
        );
        assert_eq!(changed_c_string(&mem, 0, &mut state, &mut scratch), None);

        mem.write_all_at(b"b", 128).unwrap();
        let changed = changed_c_string(&mem, 0, &mut state, &mut scratch).unwrap();
        assert_eq!(changed[128], b'b');
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn detects_same_length_change_across_large_reused_buffer() {
        let mut payload = vec![b'a'; 1024 * 1024];
        payload.extend_from_slice(b"LastInventorySync:one");
        payload.push(0);
        let path = temp_file(&payload);
        let mem = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        let mut state = ChangeState::default();
        let mut scratch = vec![0; payload.len()];

        assert!(changed_c_string(&mem, 0, &mut state, &mut scratch).is_some());
        assert_eq!(changed_c_string(&mem, 0, &mut state, &mut scratch), None);
        let changed_offset = 768 * 1024 + 16;
        mem.write_all_at(b"b", changed_offset as u64).unwrap();
        let changed = changed_c_string(&mem, 0, &mut state, &mut scratch).unwrap();
        assert_eq!(changed[changed_offset], b'b');
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn detects_reused_bounded_buffer_changes() {
        let mut payload = vec![b'a'; 288];
        payload.extend_from_slice(b"LastInventorySync:one");
        let path = temp_file(&payload);
        let mem = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        let mut state = ChangeState::default();

        assert_eq!(
            changed_buffer(&mem, 0, payload.len(), &mut state),
            Some(payload.clone())
        );
        assert_eq!(changed_buffer(&mem, 0, payload.len(), &mut state), None);

        mem.write_all_at(b"b", 128).unwrap();
        let changed = changed_buffer(&mem, 0, payload.len(), &mut state).unwrap();
        assert_eq!(changed[128], b'b');
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn finds_masked_signature() {
        let mut bytes = vec![0x90; 32];
        bytes[5..5 + HTTP_MANAGER_PATTERN.len()].copy_from_slice(HTTP_MANAGER_PATTERN);
        bytes[6] = 0xaa;
        bytes[7] = 0xbb;
        bytes[17] = 0x7f;
        assert_eq!(
            find_masked(&bytes, HTTP_MANAGER_PATTERN, HTTP_MANAGER_MASK),
            Some(5)
        );
    }

    #[test]
    fn finds_proton_anonymous_executable_mapping() {
        let maps = concat!(
            "140000000-140001000 r--p 00000000 103:0a 1 /games/Warframe.x64.exe\n",
            "140001000-142029000 r-xp 00000000 00:00 0\n",
            "142029000-14272f000 r--p 00000000 00:00 0\n",
        );
        assert_eq!(
            find_executable_region(maps),
            Some(ExecutableRegion {
                start: 0x140001000,
                end: 0x142029000,
            })
        );
    }

    fn temp_file(bytes: &[u8]) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "wfcompanion-gep-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&path, bytes).unwrap();
        path
    }

    fn put_u64(bytes: &mut [u8], offset: usize, value: u64) {
        bytes[offset..offset + 8].copy_from_slice(&value.to_le_bytes());
    }
}
