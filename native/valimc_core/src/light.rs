//! Vanilla sky and block light facts (VMC-022); `light_grid` is the engine.
//!
//! Rules (pinned `LightEngine`, `BlockLightEngine`, `SkyLightEngine`): light
//! entering a block loses `max(1, dampening)` and does not cross a face where the
//! two touching face shapes occlude. Block light starts from each state's
//! emission; sky light is 15 at and above each column's lowest sky source
//! (`ChunkSkyLightSources`: the first edge from the top that the vertical sky
//! facts block). Both are the unique fixpoint.

/// Facts from `priv/physics/light_blocks.json` and `sky_blocks.json`.
pub struct LightFacts {
    properties: Vec<u8>,
    faces: [Vec<u8>; 6],
    sizes: [usize; 6],
    occludes: [Vec<u8>; 6],
    sky_states: Vec<u8>,
    sky_size: usize,
    sky_pairs: Vec<u8>,
}

/// The opposite of each direction, in `Direction.values()` order: down, up,
/// north (−z), south (+z), west (−x), east (+x).
const OPPOSITE: [usize; 6] = [1, 0, 3, 2, 5, 4];
pub const HEIGHT: usize = 384;

fn bit(bits: &[u8], offset: usize) -> bool {
    bits[offset / 8] & (1 << (offset % 8)) != 0
}

impl LightFacts {
    pub fn new(
        properties: Vec<u8>,
        faces: [Vec<u8>; 6],
        sizes: [usize; 6],
        occludes: [Vec<u8>; 6],
        sky_states: Vec<u8>,
        sky_size: usize,
        sky_pairs: Vec<u8>,
    ) -> Option<Self> {
        let count = properties.len();
        let valid = faces.iter().all(|f| f.len() == count)
            && (0..6).all(|d| {
                faces[d].iter().all(|&c| (c as usize) < sizes[d])
                    && occludes[d].len() == (sizes[d] * sizes[OPPOSITE[d]]).div_ceil(8)
            })
            && sky_states.len() == count
            && sky_states.iter().all(|&c| (c as usize) < sky_size)
            && sky_pairs.len() == (sky_size * sky_size).div_ceil(8);
        valid.then_some(Self {
            properties,
            faces,
            sizes,
            occludes,
            sky_states,
            sky_size,
            sky_pairs,
        })
    }

    pub fn state_count(&self) -> usize {
        self.properties.len()
    }

    #[inline]
    pub fn emission(&self, state: u16) -> u8 {
        self.properties[state as usize] >> 4
    }

    #[inline]
    pub fn opacity(&self, state: u16) -> u8 {
        (self.properties[state as usize] & 15).max(1)
    }

    /// Light leaving `from` through direction `d` is stopped by `to`'s opposite face.
    #[inline]
    pub fn occludes(&self, from: u16, to: u16, d: usize) -> bool {
        let a = self.faces[d][from as usize] as usize;
        let b = self.faces[OPPOSITE[d]][to as usize] as usize;
        bit(&self.occludes[d], a * self.sizes[OPPOSITE[d]] + b)
    }

    /// The sky-source edge between `above` and `below` is blocked.
    #[inline]
    pub fn sky_blocked(&self, above: u16, below: u16) -> bool {
        let a = self.sky_states[above as usize] as usize;
        let b = self.sky_states[below as usize] as usize;
        bit(&self.sky_pairs, a * self.sky_size + b)
    }
}

/// A dense, area-wide computation of the same fixpoint: the independent
/// reference `light_grid`'s tests compare the engine with.
#[cfg(test)]
pub(crate) mod reference {
    use super::{LightFacts, HEIGHT};

    const OFFSETS: [(i32, i32, i32); 6] = [
        (0, -1, 0),
        (0, 1, 0),
        (0, 0, -1),
        (0, 0, 1),
        (-1, 0, 0),
        (1, 0, 0),
    ];

    /// A dense area `wx` × `wz` columns of `HEIGHT` cells, index `(x * wz + z) * HEIGHT + y`.
    pub(crate) struct Area<'a> {
        pub(crate) wx: usize,
        pub(crate) wz: usize,
        pub(crate) states: &'a [u16],
    }

    impl Area<'_> {
        #[inline]
        fn neighbour(&self, index: usize, d: usize) -> Option<usize> {
            let y = index % HEIGHT;
            let column = index / HEIGHT;
            let (x, z) = (column / self.wz, column % self.wz);
            let (dx, dy, dz) = OFFSETS[d];
            let (nx, ny, nz) = (
                x as i64 + dx as i64,
                y as i64 + dy as i64,
                z as i64 + dz as i64,
            );
            if nx < 0
                || nz < 0
                || ny < 0
                || nx >= self.wx as i64
                || nz >= self.wz as i64
                || ny >= HEIGHT as i64
            {
                return None;
            }
            Some((nx as usize * self.wz + nz as usize) * HEIGHT + ny as usize)
        }
    }

    /// Spread `levels` from the queued cells to the fixpoint.
    fn propagate(area: &Area, facts: &LightFacts, levels: &mut [u8], mut buckets: Vec<Vec<u32>>) {
        for level in (2..=15u8).rev() {
            let mut queue = std::mem::take(&mut buckets[level as usize]);
            while let Some(index) = queue.pop() {
                let index = index as usize;
                if levels[index] != level {
                    continue;
                }
                let from = area.states[index];
                for d in 0..6 {
                    let Some(next) = area.neighbour(index, d) else {
                        continue;
                    };
                    let to = area.states[next];
                    let opacity = facts.opacity(to);
                    if opacity >= level || levels[next] >= level - opacity {
                        continue;
                    }
                    if facts.occludes(from, to, d) {
                        continue;
                    }
                    let lit = level - opacity;
                    levels[next] = lit;
                    if lit > 1 {
                        if lit == level {
                            queue.push(next as u32);
                        } else {
                            buckets[lit as usize].push(next as u32);
                        }
                    }
                }
            }
        }
    }

    /// Block light of every cell.
    pub(crate) fn block_light(area: &Area, facts: &LightFacts) -> Vec<u8> {
        let mut levels = vec![0u8; area.states.len()];
        let mut buckets = vec![Vec::new(); 16];
        for (index, &state) in area.states.iter().enumerate() {
            let emission = facts.emission(state);
            if emission > 0 {
                levels[index] = emission;
                buckets[emission as usize].push(index as u32);
            }
        }
        propagate(area, facts, &mut levels, buckets);
        levels
    }

    /// The lowest sky source of each column (`HEIGHT` when even the top is not one).
    pub(crate) fn sky_sources(area: &Area, facts: &LightFacts) -> Vec<usize> {
        (0..area.wx * area.wz)
            .map(|column| {
                let base = column * HEIGHT;
                // Above the world is open sky (air).
                let mut above = 0u16;
                for y in (0..HEIGHT).rev() {
                    let state = area.states[base + y];
                    if facts.sky_blocked(above, state) {
                        return y + 1;
                    }
                    above = state;
                }
                0
            })
            .collect()
    }

    /// Sky light of every cell.
    pub(crate) fn sky_light(area: &Area, facts: &LightFacts) -> Vec<u8> {
        let lowest = sky_sources(area, facts);
        let mut levels = vec![0u8; area.states.len()];
        let mut buckets = vec![Vec::new(); 16];
        for x in 0..area.wx {
            for z in 0..area.wz {
                let column = x * area.wz + z;
                let low = lowest[column];
                for y in low..HEIGHT {
                    levels[column * HEIGHT + y] = 15;
                }
                // Only sources beside darker cells spread: the lowest one, and those
                // facing a neighbour column whose sources start higher.
                let mut top = low;
                for (dx, dz) in [(-1i64, 0i64), (1, 0), (0, -1), (0, 1)] {
                    let (nx, nz) = (x as i64 + dx, z as i64 + dz);
                    if nx >= 0 && nz >= 0 && (nx as usize) < area.wx && (nz as usize) < area.wz {
                        top = top.max(lowest[nx as usize * area.wz + nz as usize]);
                    }
                }
                for y in low..top.min(HEIGHT).max(low + 1).min(HEIGHT) {
                    buckets[15].push((column * HEIGHT + y) as u32);
                }
            }
        }
        propagate(area, facts, &mut levels, buckets);
        levels
    }
}
