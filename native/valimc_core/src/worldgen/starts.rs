//! A dimension's structure starts as live generation's state (VMC-077n):
//! vanilla's `STRUCTURE_STARTS`, made the first time a chunk within 8 of them
//! needs them (its terrain's beards, its decoration's pieces) and kept until
//! every chunk a start reaches is decorated. Placement changes a start in
//! place, as vanilla changes the start it saves: a temple's ground height
//! settles in the first chunk that places it, once-only pieces stay placed.
//!
//! Decorations that place the same piece always run one after the other (a
//! piece spans at most three chunks, and the generation scheduler orders
//! decorations within two chunks of each other), so a chunk's starts are
//! locked only while one decoration places one of them; decorations far
//! apart may place different pieces of one large start meanwhile.

use std::collections::{BTreeSet, HashMap};
use std::sync::{Arc, Mutex};

use super::structure::{Start, StructureEnv};

/// A start and the chunks it reaches that are not decorated yet.
struct Live {
    start: Start,
    pending: BTreeSet<(i32, i32)>,
}

/// The starts of one chunk still to place.
pub struct ChunkStarts {
    live: Mutex<Vec<Live>>,
}

/// What a snapshot keeps of a start: its structure, the chunks it still
/// reaches and each piece's placement state.
struct Saved {
    structure: usize,
    pending: Vec<(i32, i32)>,
    pieces: Vec<Vec<i32>>,
}

#[derive(Default)]
pub struct StartTable {
    chunks: Mutex<HashMap<(i32, i32), Arc<ChunkStarts>>>,
    /// Starts of a snapshot not made again yet.
    restored: Mutex<HashMap<(i32, i32), Vec<Saved>>>,
}

/// The chunks whose 16 × 16 columns a box reaches.
fn reached(start: &Start) -> BTreeSet<(i32, i32)> {
    let b = &start.bbox;
    let mut out = BTreeSet::new();
    for x in b.min_x >> 4..=b.max_x >> 4 {
        for z in b.min_z >> 4..=b.max_z >> 4 {
            out.insert((x, z));
        }
    }
    out
}

const SNAPSHOT_VERSION: u8 = 1;

impl StartTable {
    pub fn new() -> StartTable {
        StartTable::default()
    }

    /// The starts of chunk `(x, z)`, made now if needed.
    fn chunk(&self, env: &StructureEnv, x: i32, z: i32) -> Result<Arc<ChunkStarts>, String> {
        let known = self
            .chunks
            .lock()
            .map_err(|_| "start table poisoned")?
            .get(&(x, z))
            .cloned();
        if let Some(starts) = known {
            return Ok(starts);
        }
        // Made outside the lock: another job may make the same chunk
        // meanwhile, with the same starts, and the first one stays.
        let (made, _) = env.create_structures(x, z)?;
        let mut chunks = self.chunks.lock().map_err(|_| "start table poisoned")?;
        if let Some(starts) = chunks.get(&(x, z)) {
            return Ok(starts.clone());
        }
        let saved = self
            .restored
            .lock()
            .map_err(|_| "start table poisoned")?
            .remove(&(x, z));
        let mut live: Vec<Live> = made
            .into_iter()
            .map(|start| Live {
                pending: reached(&start),
                start,
            })
            .collect();
        if let Some(saved) = saved {
            live = restore(live, saved)?;
        }
        let starts = Arc::new(ChunkStarts {
            live: Mutex::new(live),
        });
        chunks.insert((x, z), starts.clone());
        Ok(starts)
    }

    /// The starts of every chunk within 8 of the chunks from `(x0, z0)` to
    /// `(x1, z1)`: all that can reach them.
    pub fn around(
        &self,
        env: &StructureEnv,
        (x0, z0): (i32, i32),
        (x1, z1): (i32, i32),
    ) -> Result<Around, String> {
        let mut chunks = HashMap::new();
        for x in x0 - 8..=x1 + 8 {
            for z in z0 - 8..=z1 + 8 {
                chunks.insert((x, z), self.chunk(env, x, z)?);
            }
        }
        Ok(Around { chunks })
    }

    /// Chunks with starts left to place and the starts among them.
    pub fn len(&self) -> (usize, usize) {
        let chunks = self
            .chunks
            .lock()
            .map_or_else(|_| HashMap::new(), |c| c.clone());
        let starts = chunks
            .values()
            .map(|c| c.live.lock().map_or(0, |l| l.len()))
            .sum();
        (chunks.len(), starts)
    }

    pub fn is_empty(&self) -> bool {
        self.len().1 == 0
    }

    /// Approximate bytes the table holds.
    pub fn heap_bytes(&self) -> usize {
        let chunks = self
            .chunks
            .lock()
            .map_or_else(|_| HashMap::new(), |c| c.clone());
        chunks
            .values()
            .map(|c| {
                64 + c.live.lock().map_or(0, |live| {
                    live.iter()
                        .map(|l| 256 + l.start.pieces.len() * 256 + l.pending.len() * 16)
                        .sum()
                })
            })
            .sum()
    }

    /// The starts left to place, for a snapshot: per chunk, per start its
    /// structure, the chunks it still reaches and its pieces' placement
    /// state (VMC-077n); chunks without starts are made again when needed.
    pub fn encode(&self) -> Result<Vec<u8>, String> {
        let chunks = self
            .chunks
            .lock()
            .map_err(|_| "start table poisoned")?
            .clone();
        let restored = self.restored.lock().map_err(|_| "start table poisoned")?;
        let mut entries: Vec<((i32, i32), Vec<Saved>)> = Vec::new();
        for (&chunk, starts) in &chunks {
            let live = starts.live.lock().map_err(|_| "start table poisoned")?;
            if !live.is_empty() {
                entries.push((
                    chunk,
                    live.iter()
                        .map(|l| Saved {
                            structure: l.start.structure,
                            pending: l.pending.iter().copied().collect(),
                            pieces: l.start.pieces.iter().map(|p| p.placement_state()).collect(),
                        })
                        .collect(),
                ));
            }
        }
        for (&chunk, saved) in restored.iter() {
            entries.push((
                chunk,
                saved
                    .iter()
                    .map(|s| Saved {
                        structure: s.structure,
                        pending: s.pending.clone(),
                        pieces: s.pieces.clone(),
                    })
                    .collect(),
            ));
        }
        entries.sort_by_key(|(chunk, _)| *chunk);
        let mut out = vec![SNAPSHOT_VERSION];
        let int = |out: &mut Vec<u8>, v: i32| out.extend(v.to_be_bytes());
        int(&mut out, entries.len() as i32);
        for ((x, z), saved) in entries {
            int(&mut out, x);
            int(&mut out, z);
            int(&mut out, saved.len() as i32);
            for s in saved {
                int(&mut out, s.structure as i32);
                int(&mut out, s.pending.len() as i32);
                for (px, pz) in s.pending {
                    int(&mut out, px);
                    int(&mut out, pz);
                }
                int(&mut out, s.pieces.len() as i32);
                for piece in s.pieces {
                    int(&mut out, piece.len() as i32);
                    for v in piece {
                        int(&mut out, v);
                    }
                }
            }
        }
        Ok(out)
    }

    /// A table holding `encode`'s starts, to be made again on first need.
    pub fn decode(bytes: &[u8]) -> Result<StartTable, String> {
        let mut input = bytes;
        let bad = || "bad start table snapshot".to_string();
        let (&version, rest) = input.split_first().ok_or_else(bad)?;
        if version != SNAPSHOT_VERSION {
            return Err(format!("start table snapshot version {version}"));
        }
        input = rest;
        let mut int = || -> Result<i32, String> {
            let (head, rest) = input.split_at_checked(4).ok_or_else(bad)?;
            input = rest;
            Ok(i32::from_be_bytes(head.try_into().map_err(|_| bad())?))
        };
        let count = |v: i32| -> Result<usize, String> {
            usize::try_from(v)
                .ok()
                .filter(|&n| n <= 1 << 24)
                .ok_or_else(bad)
        };
        let mut restored = HashMap::new();
        for _ in 0..count(int()?)? {
            let chunk = (int()?, int()?);
            let mut saved = Vec::new();
            for _ in 0..count(int()?)? {
                let structure = count(int()?)?;
                let mut pending = Vec::new();
                for _ in 0..count(int()?)? {
                    pending.push((int()?, int()?));
                }
                let mut pieces = Vec::new();
                for _ in 0..count(int()?)? {
                    let mut state = Vec::new();
                    for _ in 0..count(int()?)? {
                        state.push(int()?);
                    }
                    pieces.push(state);
                }
                saved.push(Saved {
                    structure,
                    pending,
                    pieces,
                });
            }
            restored.insert(chunk, saved);
        }
        if !input.is_empty() {
            return Err(bad());
        }
        Ok(StartTable {
            chunks: Mutex::new(HashMap::new()),
            restored: Mutex::new(restored),
        })
    }
}

/// Starts made again for a snapshot's: each saved one (matched by structure
/// in order) gets its pieces' placement state and the chunks it still
/// reaches; one the snapshot lacks was finished.
fn restore(made: Vec<Live>, saved: Vec<Saved>) -> Result<Vec<Live>, String> {
    let mut saved = saved.into_iter().peekable();
    let mut out = Vec::new();
    for mut live in made {
        let Some(s) = saved.next_if(|s| s.structure == live.start.structure) else {
            continue;
        };
        if s.pieces.len() != live.start.pieces.len() {
            return Err("a snapshot's start differs from the start made again".into());
        }
        for (piece, state) in live.start.pieces.iter_mut().zip(&s.pieces) {
            piece.restore_placement_state(state)?;
        }
        live.pending = s.pending.into_iter().collect();
        out.push(live);
    }
    if saved.next().is_some() {
        return Err("a snapshot's start is not made again".into());
    }
    Ok(out)
}

/// The starts within 8 chunks of a job's chunks.
pub struct Around {
    chunks: HashMap<(i32, i32), Arc<ChunkStarts>>,
}

impl Around {
    /// The starts as they are now, by chunk, for references and beards
    /// (which read nothing placement changes).
    pub fn view(&self) -> Result<HashMap<(i32, i32), Vec<Start>>, String> {
        self.chunks
            .iter()
            .map(|(&chunk, starts)| {
                let live = starts.live.lock().map_err(|_| "start table poisoned")?;
                Ok((chunk, live.iter().map(|l| l.start.clone()).collect()))
            })
            .collect()
    }

    /// Run `f` on chunk `source`'s start of `structure`, locked meanwhile.
    pub fn with_start(
        &self,
        source: (i32, i32),
        structure: usize,
        f: &mut dyn FnMut(&mut Start) -> Result<(), String>,
    ) -> Result<(), String> {
        let Some(starts) = self.chunks.get(&source) else {
            return Ok(());
        };
        let mut live = starts.live.lock().map_err(|_| "start table poisoned")?;
        match live.iter_mut().find(|l| l.start.structure == structure) {
            Some(l) => f(&mut l.start),
            None => Ok(()),
        }
    }

    /// `chunk` is decorated: starts that reached it no longer wait for it,
    /// and those that reach no undecorated chunk are done.
    pub fn decorated(&self, chunk: (i32, i32)) -> Result<(), String> {
        for starts in self.chunks.values() {
            let mut live = starts.live.lock().map_err(|_| "start table poisoned")?;
            live.retain_mut(|l| {
                l.pending.remove(&chunk);
                !l.pending.is_empty()
            });
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A chunk's one start: its structure, pending chunks and piece states.
    type Entry<'a> = ((i32, i32), usize, &'a [(i32, i32)], &'a [&'a [i32]]);

    fn snapshot(entries: &[Entry]) -> Vec<u8> {
        let mut out = vec![SNAPSHOT_VERSION];
        let int = |out: &mut Vec<u8>, v: i32| out.extend(v.to_be_bytes());
        int(&mut out, entries.len() as i32);
        for &((x, z), structure, pending, pieces) in entries {
            int(&mut out, x);
            int(&mut out, z);
            int(&mut out, 1);
            int(&mut out, structure as i32);
            int(&mut out, pending.len() as i32);
            for &(px, pz) in pending {
                int(&mut out, px);
                int(&mut out, pz);
            }
            int(&mut out, pieces.len() as i32);
            for piece in pieces {
                int(&mut out, piece.len() as i32);
                for &v in *piece {
                    int(&mut out, v);
                }
            }
        }
        out
    }

    #[test]
    fn a_snapshot_reads_back_as_it_was_written() {
        let bytes = snapshot(&[
            ((-4, 3), 2, &[(-4, 3)], &[&[1, 2, 3, 4, 5, 6, 0]]),
            (
                (3, -4),
                7,
                &[(3, -4), (4, -4)],
                &[&[1, 60, 3, 16, 69, 18, 64, 1, 0, 0, 1]],
            ),
        ]);
        let table = StartTable::decode(&bytes).unwrap();
        assert!(table.is_empty(), "restored starts wait until made again");
        assert_eq!(table.encode().unwrap(), bytes);
    }

    #[test]
    fn a_damaged_snapshot_is_refused() {
        let bytes = snapshot(&[((0, 0), 1, &[(0, 0)], &[&[1, 2, 3, 4, 5, 6]])]);
        let mut other = bytes.clone();
        other[0] = SNAPSHOT_VERSION + 1;
        assert!(StartTable::decode(&other).is_err());
        assert!(StartTable::decode(&bytes[..bytes.len() - 1]).is_err());
        let mut longer = bytes.clone();
        longer.push(0);
        assert!(StartTable::decode(&longer).is_err());
    }
}
