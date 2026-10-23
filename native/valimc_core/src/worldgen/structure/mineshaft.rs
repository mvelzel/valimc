//! Mineshafts (VMC-025e4, `MineshaftStructure`, `MineshaftPieces`): a room
//! at y 50 with corridors, crossings and stairs grown from it up to depth 8
//! and 80 blocks away, then moved below sea level (or, in badlands, to a
//! height up to the surface).

use super::super::blocks::{Heightmap, LIQUID, SOLID_RENDER};
use super::super::random::Random;
use super::super::region::Entity;
use super::piece::{encapsulating, BoundingBox, Direction, Piece, PieceKind};
use super::place::{Ctx, Frame};
use super::{BiomeSet, GenContext};

/// A mineshaft piece's own fields; `mesa` is the type (`MST`).
#[derive(Clone, Debug, PartialEq)]
pub enum MineshaftPiece {
    Room {
        mesa: bool,
        entrances: Vec<BoundingBox>,
    },
    Corridor {
        mesa: bool,
        has_rails: bool,
        spider_corridor: bool,
        sections: i32,
        /// Whether placement has put the cave spider spawner (`hps`).
        placed_spider: bool,
    },
    Crossing {
        mesa: bool,
        direction: Direction,
        two_floored: bool,
    },
    Stairs {
        mesa: bool,
    },
}

impl MineshaftPiece {
    pub fn id(&self) -> &'static str {
        match self {
            MineshaftPiece::Room { .. } => "minecraft:msroom",
            MineshaftPiece::Corridor { .. } => "minecraft:mscorridor",
            MineshaftPiece::Crossing { .. } => "minecraft:mscrossing",
            MineshaftPiece::Stairs { .. } => "minecraft:msstairs",
        }
    }

    /// Whether the mineshaft is a badlands one (`MST`).
    pub fn mesa(&self) -> bool {
        match self {
            MineshaftPiece::Room { mesa, .. }
            | MineshaftPiece::Corridor { mesa, .. }
            | MineshaftPiece::Crossing { mesa, .. }
            | MineshaftPiece::Stairs { mesa } => *mesa,
        }
    }

    pub fn save(&self, put: &mut dyn FnMut(&str, super::piece::Nbt)) {
        use super::piece::Nbt;
        let mesa = self.mesa();
        put("MST", Nbt::Int(mesa as i32));
        match self {
            MineshaftPiece::Room { entrances, .. } => {
                put(
                    "Entrances",
                    Nbt::List(entrances.iter().map(BoundingBox::nbt).collect()),
                );
            }
            MineshaftPiece::Corridor {
                has_rails,
                spider_corridor,
                sections,
                placed_spider,
                ..
            } => {
                put("hr", Nbt::bool(*has_rails));
                put("sc", Nbt::bool(*spider_corridor));
                put("hps", Nbt::bool(*placed_spider));
                put("Num", Nbt::Int(*sections));
            }
            MineshaftPiece::Crossing {
                direction,
                two_floored,
                ..
            } => {
                put("tf", Nbt::bool(*two_floored));
                put("D", Nbt::Byte(direction.data_2d() as i8));
            }
            MineshaftPiece::Stairs { .. } => {}
        }
    }
}

fn piece(
    kind: MineshaftPiece,
    bbox: BoundingBox,
    orientation: Option<Direction>,
    depth: i32,
) -> Piece {
    Piece {
        kind: PieceKind::Mineshaft(kind),
        bbox,
        orientation,
        gen_depth: depth,
    }
}

/// `StructurePiecesBuilder.findCollisionPiece`.
fn collides(pieces: &[Piece], b: &BoundingBox) -> bool {
    pieces.iter().any(|p| p.bbox.intersects(b))
}

/// A box made relative to a foot position, by direction.
fn boxed(
    direction: Direction,
    north: [i32; 6],
    south: [i32; 6],
    west: [i32; 6],
    east: [i32; 6],
    foot: [i32; 3],
) -> BoundingBox {
    let b = match direction {
        Direction::North => north,
        Direction::South => south,
        Direction::West => west,
        Direction::East => east,
    };
    BoundingBox::new(b[0], b[1], b[2], b[3], b[4], b[5]).moved(foot[0], foot[1], foot[2])
}

struct Builder<'a> {
    random: &'a mut Random,
    pieces: Vec<Piece>,
    mesa: bool,
    start_min: (i32, i32),
}

impl Builder<'_> {
    /// `createRandomShaftPiece`.
    fn random_shaft_piece(
        &mut self,
        foot: [i32; 3],
        direction: Direction,
        depth: i32,
    ) -> Option<Piece> {
        let selection = self.random.next_int_bounded(100);
        let mesa = self.mesa;
        if selection >= 80 {
            let y1 = if self.random.next_int_bounded(4) == 0 {
                6
            } else {
                2
            };
            let b = boxed(
                direction,
                [-1, 0, -4, 3, y1, 0],
                [-1, 0, 0, 3, y1, 4],
                [-4, 0, -1, 0, y1, 3],
                [0, 0, -1, 4, y1, 3],
                foot,
            );
            if collides(&self.pieces, &b) {
                return None;
            }
            Some(piece(
                MineshaftPiece::Crossing {
                    mesa,
                    direction,
                    two_floored: b.y_span() > 3,
                },
                b,
                None,
                depth,
            ))
        } else if selection >= 70 {
            let b = boxed(
                direction,
                [0, -5, -8, 2, 2, 0],
                [0, -5, 0, 2, 2, 8],
                [-8, -5, 0, 0, 2, 2],
                [0, -5, 0, 8, 2, 2],
                foot,
            );
            if collides(&self.pieces, &b) {
                return None;
            }
            Some(piece(
                MineshaftPiece::Stairs { mesa },
                b,
                Some(direction),
                depth,
            ))
        } else {
            let mut length = self.random.next_int_bounded(3) + 2;
            while length > 0 {
                let l = length * 5;
                let b = boxed(
                    direction,
                    [0, 0, -(l - 1), 2, 2, 0],
                    [0, 0, 0, 2, 2, l - 1],
                    [-(l - 1), 0, 0, 0, 2, 2],
                    [0, 0, 0, l - 1, 2, 2],
                    foot,
                );
                if !collides(&self.pieces, &b) {
                    let has_rails = self.random.next_int_bounded(3) == 0;
                    let spider_corridor = !has_rails && self.random.next_int_bounded(23) == 0;
                    let sections = if direction.is_z() {
                        b.z_span() / 5
                    } else {
                        b.x_span() / 5
                    };
                    return Some(piece(
                        MineshaftPiece::Corridor {
                            mesa,
                            has_rails,
                            spider_corridor,
                            sections,
                            placed_spider: false,
                        },
                        b,
                        Some(direction),
                        depth,
                    ));
                }
                length -= 1;
            }
            None
        }
    }

    /// `generateAndAddPiece`: the index of the added piece.
    fn generate_and_add(
        &mut self,
        foot: [i32; 3],
        direction: Direction,
        depth: i32,
    ) -> Option<usize> {
        if depth > 8 {
            return None;
        }
        if (foot[0] - self.start_min.0).abs() > 80 || (foot[2] - self.start_min.1).abs() > 80 {
            return None;
        }
        let new = self.random_shaft_piece(foot, direction, depth + 1)?;
        self.pieces.push(new);
        let index = self.pieces.len() - 1;
        self.add_children(index);
        Some(index)
    }

    fn add_children(&mut self, index: usize) {
        let p = self.pieces[index].clone();
        let b = p.bbox;
        let depth = p.gen_depth;
        match &p.kind {
            PieceKind::Mineshaft(MineshaftPiece::Room { .. }) => self.room_children(index),
            PieceKind::Mineshaft(MineshaftPiece::Corridor { .. }) => {
                let end = self.random.next_int_bounded(4);
                if let Some(o) = p.orientation {
                    let y = |r: &mut Random| b.min_y - 1 + r.next_int_bounded(3);
                    use Direction::*;
                    let (foot_x, foot_z, dir) = match (o, end) {
                        (North, 0 | 1) => (b.min_x, b.min_z - 1, o),
                        (North, 2) => (b.min_x - 1, b.min_z, West),
                        (North, _) => (b.max_x + 1, b.min_z, East),
                        (South, 0 | 1) => (b.min_x, b.max_z + 1, o),
                        (South, 2) => (b.min_x - 1, b.max_z - 3, West),
                        (South, _) => (b.max_x + 1, b.max_z - 3, East),
                        (West, 0 | 1) => (b.min_x - 1, b.min_z, o),
                        (West, 2) => (b.min_x, b.min_z - 1, North),
                        (West, _) => (b.min_x, b.max_z + 1, South),
                        (East, 0 | 1) => (b.max_x + 1, b.min_z, o),
                        (East, 2) => (b.max_x - 3, b.min_z - 1, North),
                        (East, _) => (b.max_x - 3, b.max_z + 1, South),
                    };
                    let foot_y = y(self.random);
                    self.generate_and_add([foot_x, foot_y, foot_z], dir, depth);
                }
                if depth < 8 {
                    if !matches!(p.orientation, Some(Direction::North | Direction::South)) {
                        let mut x = b.min_x + 3;
                        while x + 3 <= b.max_x {
                            match self.random.next_int_bounded(5) {
                                0 => {
                                    self.generate_and_add(
                                        [x, b.min_y, b.min_z - 1],
                                        Direction::North,
                                        depth + 1,
                                    );
                                }
                                1 => {
                                    self.generate_and_add(
                                        [x, b.min_y, b.max_z + 1],
                                        Direction::South,
                                        depth + 1,
                                    );
                                }
                                _ => {}
                            }
                            x += 5;
                        }
                    } else {
                        let mut z = b.min_z + 3;
                        while z + 3 <= b.max_z {
                            match self.random.next_int_bounded(5) {
                                0 => {
                                    self.generate_and_add(
                                        [b.min_x - 1, b.min_y, z],
                                        Direction::West,
                                        depth + 1,
                                    );
                                }
                                1 => {
                                    self.generate_and_add(
                                        [b.max_x + 1, b.min_y, z],
                                        Direction::East,
                                        depth + 1,
                                    );
                                }
                                _ => {}
                            }
                            z += 5;
                        }
                    }
                }
            }
            PieceKind::Mineshaft(MineshaftPiece::Crossing {
                direction,
                two_floored,
                ..
            }) => {
                use Direction::*;
                let y = b.min_y;
                let north = ([b.min_x + 1, y, b.min_z - 1], North);
                let south = ([b.min_x + 1, y, b.max_z + 1], South);
                let west = ([b.min_x - 1, y, b.min_z + 1], West);
                let east = ([b.max_x + 1, y, b.min_z + 1], East);
                let order = match direction {
                    North => [north, west, east],
                    South => [south, west, east],
                    West => [north, south, west],
                    East => [north, south, east],
                };
                for (foot, dir) in order {
                    self.generate_and_add(foot, dir, depth);
                }
                if *two_floored {
                    let y = b.min_y + 3 + 1;
                    for (foot, dir) in [
                        ([b.min_x + 1, y, b.min_z - 1], North),
                        ([b.min_x - 1, y, b.min_z + 1], West),
                        ([b.max_x + 1, y, b.min_z + 1], East),
                        ([b.min_x + 1, y, b.max_z + 1], South),
                    ] {
                        if self.random.next_bool() {
                            self.generate_and_add(foot, dir, depth);
                        }
                    }
                }
            }
            PieceKind::Mineshaft(MineshaftPiece::Stairs { .. }) => {
                if let Some(o) = p.orientation {
                    let foot = match o {
                        Direction::North => [b.min_x, b.min_y, b.min_z - 1],
                        Direction::South => [b.min_x, b.min_y, b.max_z + 1],
                        Direction::West => [b.min_x - 1, b.min_y, b.min_z],
                        Direction::East => [b.max_x + 1, b.min_y, b.min_z],
                    };
                    self.generate_and_add(foot, o, depth);
                }
            }
            _ => {}
        }
    }

    /// `MineShaftRoom.addChildren`: exits along each side, each remembered
    /// as an entrance box.
    fn room_children(&mut self, index: usize) {
        let b = self.pieces[index].bbox;
        let depth = self.pieces[index].gen_depth;
        let height_space = (b.y_span() - 3 - 1).max(1);
        for side in 0..4 {
            let span = if side < 2 { b.x_span() } else { b.z_span() };
            let mut pos = 0;
            while pos < span {
                pos += self.random.next_int_bounded(span);
                if pos + 3 > span {
                    break;
                }
                let y = b.min_y + self.random.next_int_bounded(height_space) + 1;
                let (foot, dir) = match side {
                    0 => ([b.min_x + pos, y, b.min_z - 1], Direction::North),
                    1 => ([b.min_x + pos, y, b.max_z + 1], Direction::South),
                    2 => ([b.min_x - 1, y, b.min_z + pos], Direction::West),
                    _ => ([b.max_x + 1, y, b.min_z + pos], Direction::East),
                };
                if let Some(child) = self.generate_and_add(foot, dir, depth) {
                    let c = self.pieces[child].bbox;
                    let entrance = match side {
                        0 => BoundingBox::new(
                            c.min_x,
                            c.min_y,
                            b.min_z,
                            c.max_x,
                            c.max_y,
                            b.min_z + 1,
                        ),
                        1 => BoundingBox::new(
                            c.min_x,
                            c.min_y,
                            b.max_z - 1,
                            c.max_x,
                            c.max_y,
                            b.max_z,
                        ),
                        2 => BoundingBox::new(
                            b.min_x,
                            c.min_y,
                            c.min_z,
                            b.min_x + 1,
                            c.max_y,
                            c.max_z,
                        ),
                        _ => BoundingBox::new(
                            b.max_x - 1,
                            c.min_y,
                            c.min_z,
                            b.max_x,
                            c.max_y,
                            c.max_z,
                        ),
                    };
                    if let PieceKind::Mineshaft(MineshaftPiece::Room { entrances, .. }) =
                        &mut self.pieces[index].kind
                    {
                        entrances.push(entrance);
                    }
                }
                pos += 4;
            }
        }
    }
}

/// `MineshaftStructure.findGenerationPoint`: the pieces are laid out before
/// the biome check at the moved start.
pub fn generate(gc: &mut GenContext, mesa: bool) -> Result<Option<Vec<Piece>>, String> {
    gc.random.next_double();
    let (min_x, min_z) = (gc.min_block_x(), gc.min_block_z());
    let r = &mut gc.random;
    let x1 = min_x + 2 + 7 + r.next_int_bounded(6);
    let y1 = 54 + r.next_int_bounded(6);
    let z1 = min_z + 2 + 7 + r.next_int_bounded(6);
    let room = piece(
        MineshaftPiece::Room {
            mesa,
            entrances: Vec::new(),
        },
        BoundingBox::new(min_x + 2, 50, min_z + 2, x1, y1, z1),
        None,
        0,
    );
    let mut builder = Builder {
        random: &mut gc.random,
        pieces: vec![room],
        mesa,
        start_min: (min_x + 2, min_z + 2),
    };
    builder.add_children(0);
    let mut pieces = builder.pieces;
    let sea_level = gc.sea_level();
    let bb = encapsulating(pieces.iter().map(|p| &p.bbox)).expect("a room");
    let dy = if mesa {
        let (cx, cy, cz) = bb.center();
        let surface = gc.base_height(cx, cz, Heightmap::WorldSurfaceWg)?;
        let target = if surface <= sea_level {
            sea_level
        } else {
            gc.random.next_int_bounded(surface - sea_level + 1) + sea_level
        };
        target - cy
    } else {
        // `moveBelowSeaLevel` with the generator's minimum height.
        let max_y = sea_level - 10;
        let mut y1 = bb.y_span() + gc.env.heights.min_y + 1;
        if y1 < max_y {
            y1 += gc.random.next_int_bounded(max_y - y1);
        }
        y1 - bb.max_y
    };
    for p in &mut pieces {
        p.moved_by(0, dy, 0);
    }
    if !gc.is_valid_biome((min_x + 8, 50 + dy, min_z)) {
        return Ok(None);
    }
    Ok(Some(pieces))
}

// Placement (VMC-025f4): each piece's `postProcess`.

const UP: usize = 1;
/// `Direction.values()` as steps.
const DIRECTIONS: [(i32, i32, i32); 6] = [
    (0, -1, 0),
    (0, 1, 0),
    (0, 0, -1),
    (0, 0, 1),
    (-1, 0, 0),
    (1, 0, 0),
];

fn opposite(d: usize) -> usize {
    d ^ 1
}

const MINESHAFT_LOOT: &str = "minecraft:chests/abandoned_mineshaft";

/// A mineshaft type's wood, planks and fence.
struct Wood {
    log: u16,
    planks: u16,
    fence: u16,
}

impl Wood {
    fn of(c: &Ctx, mesa: bool) -> Result<Wood, String> {
        let (log, planks, fence) = if mesa {
            ("dark_oak_log", "dark_oak_planks", "dark_oak_fence")
        } else {
            ("oak_log", "oak_planks", "oak_fence")
        };
        Ok(Wood {
            log: c.state(log)?,
            planks: c.state(planks)?,
            fence: c.state(fence)?,
        })
    }
}

pub fn post_process(piece: &mut Piece, c: &mut Ctx, blocking: &BiomeSet) -> Result<(), String> {
    let PieceKind::Mineshaft(kind) = &mut piece.kind else {
        return Err("not a mineshaft piece".into());
    };
    let mesa = kind.mesa();
    let wood = Wood::of(c, mesa)?;
    let table = c.placer.table;
    // `MineShaftPiece.canBeReplaced`: never over its own wood or chains.
    let guard = [
        table.block_of(wood.planks),
        table.block_of(wood.log),
        table.block_of(wood.fence),
        table.block("iron_chain")?,
    ];
    let mut f = Frame::new(piece.bbox, piece.orientation);
    f.guard = Some(guard);
    if invalid_location(&piece.bbox, c, blocking)? {
        return Ok(());
    }
    let cave_air = c.state("cave_air")?;
    match kind {
        MineshaftPiece::Corridor {
            has_rails,
            spider_corridor,
            sections,
            placed_spider,
            ..
        } => corridor(
            c,
            &f,
            &wood,
            cave_air,
            *has_rails,
            *spider_corridor,
            *sections,
            placed_spider,
        ),
        MineshaftPiece::Crossing { two_floored, .. } => {
            crossing(c, &f, &wood, cave_air, *two_floored, piece.bbox);
            Ok(())
        }
        MineshaftPiece::Room { entrances, .. } => {
            let b = piece.bbox;
            c.generate_box(
                &f,
                (b.min_x, b.min_y + 1, b.min_z),
                (b.max_x, (b.min_y + 3).min(b.max_y), b.max_z),
                cave_air,
                cave_air,
                false,
            );
            for e in entrances.iter() {
                c.generate_box(
                    &f,
                    (e.min_x, e.max_y - 2, e.min_z),
                    (e.max_x, e.max_y, e.max_z),
                    cave_air,
                    cave_air,
                    false,
                );
            }
            c.upper_half_sphere(
                &f,
                (b.min_x, b.min_y + 4, b.min_z),
                (b.max_x, b.max_y, b.max_z),
                cave_air,
                false,
            );
            Ok(())
        }
        MineshaftPiece::Stairs { .. } => {
            c.generate_box(&f, (0, 5, 0), (2, 7, 1), cave_air, cave_air, false);
            c.generate_box(&f, (0, 0, 7), (2, 2, 8), cave_air, cave_air, false);
            for i in 0..5 {
                let step = if i < 4 { 1 } else { 0 };
                c.generate_box(
                    &f,
                    (0, 5 - i - step, 2 + i),
                    (2, 7 - i, 2 + i),
                    cave_air,
                    cave_air,
                    false,
                );
            }
            Ok(())
        }
    }
}

/// `isInInvalidLocation`: in a biome mineshafts avoid (at the middle of the
/// piece's part of the chunk, grown by one), or touching liquid on that
/// part's faces.
fn invalid_location(b: &BoundingBox, c: &mut Ctx, blocking: &BiomeSet) -> Result<bool, String> {
    let k = c.chunk_box;
    let (x0, y0, z0) = (
        (b.min_x - 1).max(k.min_x),
        (b.min_y - 1).max(k.min_y),
        (b.min_z - 1).max(k.min_z),
    );
    let (x1, y1, z1) = (
        (b.max_x + 1).min(k.max_x),
        (b.max_y + 1).min(k.max_y),
        (b.max_z + 1).min(k.max_z),
    );
    let biome = c
        .region
        .biome([(x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2]);
    if blocking.contains(biome) {
        return Ok(true);
    }
    let table = c.placer.table;
    let mut liquid = |p: [i32; 3]| table.flag(c.region.get(p), LIQUID);
    for x in x0..=x1 {
        for z in z0..=z1 {
            if liquid([x, y0, z]) || liquid([x, y1, z]) {
                return Ok(true);
            }
        }
    }
    for x in x0..=x1 {
        for y in y0..=y1 {
            if liquid([x, y, z0]) || liquid([x, y, z1]) {
                return Ok(true);
            }
        }
    }
    for z in z0..=z1 {
        for y in y0..=y1 {
            if liquid([x0, y, z]) || liquid([x1, y, z]) {
                return Ok(true);
            }
        }
    }
    Ok(false)
}

#[allow(clippy::too_many_arguments)]
fn corridor(
    c: &mut Ctx,
    f: &Frame,
    wood: &Wood,
    cave_air: u16,
    has_rails: bool,
    spider_corridor: bool,
    sections: i32,
    placed_spider: &mut bool,
) -> Result<(), String> {
    let length = sections * 5 - 1;
    c.generate_box(f, (0, 0, 0), (2, 1, length), cave_air, cave_air, false);
    c.maybe_box(
        f,
        0.8,
        (0, 2, 0),
        (2, 2, length),
        cave_air,
        cave_air,
        false,
        false,
    );
    if spider_corridor {
        let cobweb = c.state("cobweb")?;
        c.maybe_box(
            f,
            0.6,
            (0, 0, 0),
            (2, 1, length),
            cobweb,
            cave_air,
            false,
            true,
        );
    }
    for section in 0..sections {
        let z = 2 + section * 5;
        support(c, f, wood, cave_air, 0, 0, z, 2, 2)?;
        for (probability, x, dz) in [
            (0.1, 0, -1),
            (0.1, 2, -1),
            (0.1, 0, 1),
            (0.1, 2, 1),
            (0.05, 0, -2),
            (0.05, 2, -2),
            (0.05, 0, 2),
            (0.05, 2, 2),
        ] {
            maybe_cobweb(c, f, probability, x, 2, z + dz)?;
        }
        if c.random.next_int_bounded(100) == 0 {
            minecart_chest(c, f, 2, 0, z - 1)?;
        }
        if c.random.next_int_bounded(100) == 0 {
            minecart_chest(c, f, 0, 0, z + 1)?;
        }
        if spider_corridor && !*placed_spider {
            let spider_z = z - 1 + c.random.next_int_bounded(3);
            let pos = f.world(1, 0, spider_z);
            if c.chunk_box.is_inside(pos[0], pos[1], pos[2]) && c.is_interior(f, 1, 0, spider_z) {
                *placed_spider = true;
                let spawner = c.state("spawner")?;
                c.set(pos, spawner, 2);
                if let Some(entity) = c.region.block_entity(pos)? {
                    if entity.kind == "minecraft:mob_spawner" {
                        entity.spawner_entity = Some("minecraft:cave_spider".into());
                    }
                }
            }
        }
    }
    for x in 0..=2 {
        for z in 0..=length {
            planks_block(c, f, wood.planks, x, -1, z);
        }
    }
    double_support(c, f, wood, 0, -1, 2)?;
    if sections > 1 {
        double_support(c, f, wood, 0, -1, length - 2)?;
    }
    if has_rails {
        let rail = c.state("rail[shape=north_south]")?;
        for z in 0..=length {
            let floor = c.get_block(f, 1, -1, z);
            if !c.placer.table.is_air(floor) && c.placer.table.flag(floor, SOLID_RENDER) {
                let probability = if c.is_interior(f, 1, 0, z) { 0.7 } else { 0.9 };
                c.maybe_block(f, probability, 1, 0, z, rail);
            }
        }
    }
    Ok(())
}

/// `MineShaftCorridor.createChest`: a minecart with a chest on a rail, over
/// ground, in air.
fn minecart_chest(c: &mut Ctx, f: &Frame, x: i32, y: i32, z: i32) -> Result<bool, String> {
    let pos = f.world(x, y, z);
    if !c.chunk_box.is_inside(pos[0], pos[1], pos[2])
        || !c.placer.table.is_air(c.region.get(pos))
        || c.placer
            .table
            .is_air(c.region.get([pos[0], pos[1] - 1, pos[2]]))
    {
        return Ok(false);
    }
    let shape = if c.random.next_bool() {
        "north_south"
    } else {
        "east_west"
    };
    let rail = c.placer.with(c.state("rail")?, "shape", shape);
    c.place(f, rail, x, y, z);
    let seed = c.random.next_long();
    c.region.add_entity(Entity {
        kind: "minecraft:chest_minecart",
        pos: [
            pos[0] as f64 + 0.5,
            pos[1] as f64 + 0.5,
            pos[2] as f64 + 0.5,
        ],
        // `AbstractMinecartContainer`'s loot table and seed as it saves them.
        nbt: Some(format!("{{LootTable:\"{MINESHAFT_LOOT}\",LootTableSeed:{seed}L}}").into()),
        ..Entity::default()
    });
    Ok(true)
}

/// `placeSupport`: fences and a planks beam (or two planks) across the
/// corridor where the ceiling above is solid, sometimes with torches.
#[allow(clippy::too_many_arguments)]
fn support(
    c: &mut Ctx,
    f: &Frame,
    wood: &Wood,
    cave_air: u16,
    x0: i32,
    y0: i32,
    z: i32,
    y1: i32,
    x1: i32,
) -> Result<(), String> {
    if !(x0..=x1).all(|x| !c.placer.table.is_air(c.get_block(f, x, y1 + 1, z))) {
        return Ok(());
    }
    let west = c.placer.with(wood.fence, "west", "true");
    let east = c.placer.with(wood.fence, "east", "true");
    c.generate_box(f, (x0, y0, z), (x0, y1 - 1, z), west, cave_air, false);
    c.generate_box(f, (x1, y0, z), (x1, y1 - 1, z), east, cave_air, false);
    if c.random.next_int_bounded(4) == 0 {
        c.generate_box(f, (x0, y1, z), (x0, y1, z), wood.planks, cave_air, false);
        c.generate_box(f, (x1, y1, z), (x1, y1, z), wood.planks, cave_air, false);
    } else {
        c.generate_box(f, (x0, y1, z), (x1, y1, z), wood.planks, cave_air, false);
        let south = c.state("wall_torch[facing=south]")?;
        let north = c.state("wall_torch[facing=north]")?;
        c.maybe_block(f, 0.05, x0 + 1, y1, z - 1, south);
        c.maybe_block(f, 0.05, x0 + 1, y1, z + 1, north);
    }
    Ok(())
}

/// `maybePlaceCobWeb`: inside, by chance, with two sturdy neighbours.
fn maybe_cobweb(
    c: &mut Ctx,
    f: &Frame,
    probability: f32,
    x: i32,
    y: i32,
    z: i32,
) -> Result<(), String> {
    if !c.is_interior(f, x, y, z) || c.random.next_float() >= probability {
        return Ok(());
    }
    let pos = f.world(x, y, z);
    let mut sturdy = 0;
    // `Direction.values()`, each neighbour's face toward the position.
    for (d, (dx, dy, dz)) in DIRECTIONS.iter().enumerate() {
        let at = [pos[0] + dx, pos[1] + dy, pos[2] + dz];
        if c.chunk_box.is_inside(at[0], at[1], at[2])
            && c.placer.sturdy(c.region.get(at), opposite(d))
        {
            sturdy += 1;
            if sturdy >= 2 {
                let cobweb = c.state("cobweb")?;
                c.place(f, cobweb, x, y, z);
                return Ok(());
            }
        }
    }
    Ok(())
}

/// `setPlanksBlock`: planks under the corridor where the floor is not
/// sturdy, inside only.
fn planks_block(c: &mut Ctx, f: &Frame, planks: u16, x: i32, y: i32, z: i32) {
    if c.is_interior(f, x, y, z) {
        let pos = f.world(x, y, z);
        if !c.placer.sturdy(c.region.get(pos), UP) {
            c.set(pos, planks, 2);
        }
    }
}

/// `placeDoubleLowerOrUpperSupport`: log pillars down (or chains up) under
/// a support's planks.
fn double_support(
    c: &mut Ctx,
    f: &Frame,
    wood: &Wood,
    x: i32,
    y: i32,
    z: i32,
) -> Result<(), String> {
    let planks = c.placer.table.block_of(wood.planks);
    if c.placer.table.block_of(c.get_block(f, x, y, z)) == planks {
        pillar_or_chain(c, f, wood, x, y, z)?;
    }
    if c.placer.table.block_of(c.get_block(f, x + 2, y, z)) == planks {
        pillar_or_chain(c, f, wood, x + 2, y, z)?;
    }
    Ok(())
}

/// `fillPillarDownOrChainUp`.
fn pillar_or_chain(
    c: &mut Ctx,
    f: &Frame,
    wood: &Wood,
    x: i32,
    y: i32,
    z: i32,
) -> Result<(), String> {
    let pos = f.world(x, y, z);
    if !c.chunk_box.is_inside(pos[0], pos[1], pos[2]) {
        return Ok(());
    }
    let (min_y, max_y) = (c.region.min_y(), c.region.min_y() + c.region.height() - 1);
    let table = c.placer.table;
    let lava = table.block("lava")?;
    let world_y = pos[1];
    let (mut below, mut above) = (true, true);
    let mut distance = 1;
    while below || above {
        if below {
            let at = [pos[0], world_y - distance, pos[2]];
            let state = c.region.get(at);
            let empty = c.placer.replaceable_by_structures(state) && table.block_of(state) != lava;
            if !empty && c.placer.sturdy(state, UP) {
                for py in world_y - distance + 1..world_y {
                    c.set([pos[0], py, pos[2]], wood.log, 2);
                }
                return Ok(());
            }
            below = distance <= 20 && empty && at[1] > min_y + 1;
        }
        if above {
            let at = [pos[0], world_y + distance, pos[2]];
            let state = c.region.get(at);
            let empty = c.placer.replaceable_by_structures(state);
            if !empty && c.placer.center_support_down(state) && !c.placer.falling(state) {
                c.set([pos[0], world_y + 1, pos[2]], wood.fence, 2);
                let chain = c.state("iron_chain")?;
                for py in world_y + 2..world_y + distance {
                    c.set([pos[0], py, pos[2]], chain, 2);
                }
                return Ok(());
            }
            above = distance <= 50 && empty && at[1] < max_y;
        }
        distance += 1;
    }
    Ok(())
}

fn crossing(c: &mut Ctx, f: &Frame, wood: &Wood, cave_air: u16, two_floored: bool, b: BoundingBox) {
    if two_floored {
        c.generate_box(
            f,
            (b.min_x + 1, b.min_y, b.min_z),
            (b.max_x - 1, b.min_y + 2, b.max_z),
            cave_air,
            cave_air,
            false,
        );
        c.generate_box(
            f,
            (b.min_x, b.min_y, b.min_z + 1),
            (b.max_x, b.min_y + 2, b.max_z - 1),
            cave_air,
            cave_air,
            false,
        );
        c.generate_box(
            f,
            (b.min_x + 1, b.max_y - 2, b.min_z),
            (b.max_x - 1, b.max_y, b.max_z),
            cave_air,
            cave_air,
            false,
        );
        c.generate_box(
            f,
            (b.min_x, b.max_y - 2, b.min_z + 1),
            (b.max_x, b.max_y, b.max_z - 1),
            cave_air,
            cave_air,
            false,
        );
        c.generate_box(
            f,
            (b.min_x + 1, b.min_y + 3, b.min_z + 1),
            (b.max_x - 1, b.min_y + 3, b.max_z - 1),
            cave_air,
            cave_air,
            false,
        );
    } else {
        c.generate_box(
            f,
            (b.min_x + 1, b.min_y, b.min_z),
            (b.max_x - 1, b.max_y, b.max_z),
            cave_air,
            cave_air,
            false,
        );
        c.generate_box(
            f,
            (b.min_x, b.min_y, b.min_z + 1),
            (b.max_x, b.max_y, b.max_z - 1),
            cave_air,
            cave_air,
            false,
        );
    }
    for (x, z) in [
        (b.min_x + 1, b.min_z + 1),
        (b.min_x + 1, b.max_z - 1),
        (b.max_x - 1, b.min_z + 1),
        (b.max_x - 1, b.max_z - 1),
    ] {
        // `placeSupportPillar`: under a solid ceiling.
        if !c.placer.table.is_air(c.get_block(f, x, b.max_y + 1, z)) {
            c.generate_box(
                f,
                (x, b.min_y, z),
                (x, b.max_y, z),
                wood.planks,
                cave_air,
                false,
            );
        }
    }
    for x in b.min_x..=b.max_x {
        for z in b.min_z..=b.max_z {
            planks_block(c, f, wood.planks, x, b.min_y - 1, z);
        }
    }
}
