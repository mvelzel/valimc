//! Large plants that are not trees (VMC-025b): huge mushrooms and bamboo.

use std::sync::Arc;

use super::blocks::{BlockSet, BlockTable, Heightmap};
use super::feature::Decoration;
use super::json::Json;
use super::predicate::{offset, BlockPredicate};
use super::random::Random;
use super::region::Region;
use super::state_provider::StateProvider;

/// `HugeRedMushroomFeature` and `HugeBrownMushroomFeature`.
#[derive(Debug)]
pub struct HugeMushroom {
    red: bool,
    cap: Arc<StateProvider>,
    stem: Arc<StateProvider>,
    foliage_radius: i32,
    can_place_on: BlockPredicate,
    leaves: BlockSet,
    replaceable: BlockSet,
}

impl HugeMushroom {
    pub fn parse(
        json: &Json,
        table: &BlockTable,
        red: bool,
        provider: &mut dyn FnMut(&Json) -> Result<Arc<StateProvider>, String>,
    ) -> Result<HugeMushroom, String> {
        Ok(HugeMushroom {
            red,
            cap: provider(json.field("cap_provider")?)?,
            stem: provider(json.field("stem_provider")?)?,
            foliage_radius: json.get("foliage_radius").map_or(Ok(2), Json::as_i32)?,
            can_place_on: BlockPredicate::parse(json.field("can_place_on")?, table)?,
            leaves: table.tag("minecraft:leaves")?.clone(),
            replaceable: table.tag("minecraft:replaceable_by_mushrooms")?.clone(),
        })
    }

    /// `getTreeRadiusForHeight(-1, -1, radius, dy)`: for red mushrooms the
    /// trunk and tree heights vanilla passes leave every radius zero.
    fn radius_at(&self, dy: i32) -> i32 {
        if self.red || dy <= 3 {
            0
        } else {
            self.foliage_radius
        }
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let mut height = random.next_int_bounded(3) + 4;
        if random.next_int_bounded(12) == 0 {
            height *= 2;
        }
        if !self.valid_position(d, region, origin, height) {
            return Ok(false);
        }
        if self.red {
            self.red_cap(d, region, random, origin, height);
        } else {
            self.brown_cap(d, region, random, origin, height);
        }
        for dy in 0..height {
            let state = self.stem.state(d, region, random, origin);
            self.place_block(d, region, offset(origin, [0, dy, 0]), state);
        }
        Ok(true)
    }

    fn valid_position(
        &self,
        d: &Decoration,
        region: &mut Region,
        origin: [i32; 3],
        height: i32,
    ) -> bool {
        let y = origin[1];
        let min_y = d.context().min_y;
        let max_y = min_y + d.context().height - 1;
        if y < min_y + 1 || y + height + 1 > max_y {
            return false;
        }
        if !self
            .can_place_on
            .test(d, region, offset(origin, [0, -1, 0]))
        {
            return false;
        }
        for dy in 0..=height {
            let r = self.radius_at(dy);
            for dx in -r..=r {
                for dz in -r..=r {
                    let state = region.get(offset(origin, [dx, dy, dz]));
                    if !d.table.is_air(state) && !d.table.in_tag(state, &self.leaves) {
                        return false;
                    }
                }
            }
        }
        true
    }

    /// `placeMushroomBlock`: only into air or what mushrooms replace,
    /// with neighbour updates (none in a generation region).
    fn place_block(&self, d: &Decoration, region: &mut Region, pos: [i32; 3], state: u16) {
        let current = region.get(pos);
        if d.table.is_air(current) || d.table.in_tag(current, &self.replaceable) {
            region.set(pos, state, 3);
        }
    }

    fn faces(table: &BlockTable, state: u16, faces: &[(&str, bool)]) -> u16 {
        if !faces.iter().all(|(f, _)| table.has_property(state, f)) {
            return state;
        }
        faces.iter().fold(state, |s, (f, v)| {
            table
                .with(s, f, if *v { "true" } else { "false" })
                .unwrap_or(s)
        })
    }

    fn red_cap(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
        height: i32,
    ) {
        let table = d.table.as_ref();
        let fr = self.foliage_radius;
        for dy in height - 3..=height {
            let radius = if dy < height { fr } else { fr - 1 };
            let center = fr - 2;
            for dx in -radius..=radius {
                for dz in -radius..=radius {
                    let x_edge = dx == -radius || dx == radius;
                    let z_edge = dz == -radius || dz == radius;
                    if dy >= height || x_edge != z_edge {
                        let pos = offset(origin, [dx, dy, dz]);
                        let state = self.cap.state(d, region, random, origin);
                        let state = Self::faces(
                            table,
                            state,
                            &[
                                ("up", dy >= height - 1),
                                ("west", dx < -center),
                                ("east", dx > center),
                                ("north", dz < -center),
                                ("south", dz > center),
                            ],
                        );
                        self.place_block(d, region, pos, state);
                    }
                }
            }
        }
    }

    fn brown_cap(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
        height: i32,
    ) {
        let table = d.table.as_ref();
        let r = self.foliage_radius;
        for dx in -r..=r {
            for dz in -r..=r {
                let (min_x, max_x, min_z, max_z) = (dx == -r, dx == r, dz == -r, dz == r);
                let x_edge = min_x || max_x;
                let z_edge = min_z || max_z;
                if x_edge && z_edge {
                    continue;
                }
                let pos = offset(origin, [dx, height, dz]);
                let west = min_x || (z_edge && dx == 1 - r);
                let east = max_x || (z_edge && dx == r - 1);
                let north = min_z || (x_edge && dz == 1 - r);
                let south = max_z || (x_edge && dz == r - 1);
                let state = self.cap.state(d, region, random, origin);
                let state = Self::faces(
                    table,
                    state,
                    &[
                        ("west", west),
                        ("east", east),
                        ("north", north),
                        ("south", south),
                    ],
                );
                self.place_block(d, region, pos, state);
            }
        }
    }
}

/// `BambooFeature`: a stalk with leaves on top, on a podzol disc by chance.
#[derive(Debug)]
pub struct Bamboo {
    probability: f32,
    trunk: u16,
    final_large: u16,
    top_large: u16,
    top_small: u16,
    sapling_test: u16,
    podzol: u16,
    podzol_replaceable: BlockSet,
}

impl Bamboo {
    pub fn parse(json: &Json, table: &BlockTable) -> Result<Bamboo, String> {
        let default = table.default_state("bamboo")?;
        let set =
            |s: u16, p: &str, v: &str| table.with(s, p, v).ok_or_else(|| format!("bamboo {p}"));
        let trunk = set(
            set(set(default, "age", "1")?, "leaves", "none")?,
            "stage",
            "0",
        )?;
        Ok(Bamboo {
            probability: json.field("probability")?.as_f64()? as f32,
            trunk,
            final_large: set(set(trunk, "leaves", "large")?, "stage", "1")?,
            top_large: set(trunk, "leaves", "large")?,
            top_small: set(trunk, "leaves", "small")?,
            sapling_test: default,
            podzol: table.default_state("podzol")?,
            podzol_replaceable: table
                .tag("minecraft:beneath_bamboo_podzol_replaceable")?
                .clone(),
        })
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        if !region.is_air_at(origin) {
            return Ok(false);
        }
        if d.survives(region, self.sapling_test, origin) {
            let height = random.next_int_bounded(12) + 5;
            if random.next_float() < self.probability {
                let r = random.next_int_bounded(4) + 1;
                for x in origin[0] - r..=origin[0] + r {
                    for z in origin[2] - r..=origin[2] + r {
                        let (xd, zd) = (x - origin[0], z - origin[2]);
                        if xd * xd + zd * zd <= r * r {
                            let y = region.height_at(Heightmap::WorldSurface, x, z) - 1;
                            let state = region.get([x, y, z]);
                            if d.table.in_tag(state, &self.podzol_replaceable) {
                                region.set([x, y, z], self.podzol, 2);
                            }
                        }
                    }
                }
            }
            let mut pos = origin;
            let mut i = 0;
            while i < height && region.is_air_at(pos) {
                region.set(pos, self.trunk, 2);
                pos[1] += 1;
                i += 1;
            }
            if pos[1] - origin[1] >= 3 {
                region.set(pos, self.final_large, 2);
                pos[1] -= 1;
                region.set(pos, self.top_large, 2);
                pos[1] -= 1;
                region.set(pos, self.top_small, 2);
            }
        }
        Ok(true)
    }
}
