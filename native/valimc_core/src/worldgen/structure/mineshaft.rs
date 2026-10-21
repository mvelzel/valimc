//! Mineshafts (VMC-025e4, `MineshaftStructure`, `MineshaftPieces`): a room
//! at y 50 with corridors, crossings and stairs grown from it up to depth 8
//! and 80 blocks away, then moved below sea level (or, in badlands, to a
//! height up to the surface).

use super::super::blocks::Heightmap;
use super::super::random::Random;
use super::piece::{encapsulating, BoundingBox, Direction, Piece, PieceKind};
use super::GenContext;

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

    pub fn save(&self, put: &mut dyn FnMut(&str, super::piece::Nbt)) {
        use super::piece::Nbt;
        let mesa = match self {
            MineshaftPiece::Room { mesa, .. }
            | MineshaftPiece::Corridor { mesa, .. }
            | MineshaftPiece::Crossing { mesa, .. }
            | MineshaftPiece::Stairs { mesa } => *mesa,
        };
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
                ..
            } => {
                put("hr", Nbt::bool(*has_rails));
                put("sc", Nbt::bool(*spider_corridor));
                put("hps", Nbt::bool(false));
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
        let surface = gc
            .env
            .heights
            .base_height(cx, cz, Heightmap::WorldSurfaceWg)?;
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
