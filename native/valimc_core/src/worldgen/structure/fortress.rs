//! Nether fortresses (VMC-025e4, `NetherFortressStructure`,
//! `NetherFortressPieces`): a bridge crossing at y 64 growing bridges and
//! castle corridors from two weighted piece lists (pending children in random
//! order, end fillers where nothing fits), then moved to between y 48 and 70.
//! Vanilla's start piece is a bridge crossing and saves as one.

use super::super::blocks::FLUID_LAVA;
use super::super::random::Random;
use super::piece::{
    encapsulating, make_bounding_box, BoundingBox, Direction, Nbt, Piece, PieceKind,
};
use super::place::{Ctx, Frame};
use super::GenContext;

/// A fortress piece's type and own fields.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum FortressPiece {
    BridgeCrossing,
    BridgeEndFiller {
        seed: i32,
    },
    BridgeStraight,
    CorridorStairs,
    CorridorTBalcony,
    Entrance,
    SmallCorridorCrossing,
    SmallCorridorLeftTurn {
        chest: bool,
    },
    SmallCorridor,
    SmallCorridorRightTurn {
        chest: bool,
    },
    StalkRoom,
    /// Whether placement has put the blaze spawner (`Mob`).
    MonsterThrone {
        spawner: bool,
    },
    RoomCrossing,
    StairsRoom,
}

impl FortressPiece {
    pub fn id(&self) -> &'static str {
        match self {
            FortressPiece::BridgeCrossing => "minecraft:nebcr",
            FortressPiece::BridgeEndFiller { .. } => "minecraft:nebef",
            FortressPiece::BridgeStraight => "minecraft:nebs",
            FortressPiece::CorridorStairs => "minecraft:neccs",
            FortressPiece::CorridorTBalcony => "minecraft:nectb",
            FortressPiece::Entrance => "minecraft:nece",
            FortressPiece::SmallCorridorCrossing => "minecraft:nescsc",
            FortressPiece::SmallCorridorLeftTurn { .. } => "minecraft:nesclt",
            FortressPiece::SmallCorridor => "minecraft:nesc",
            FortressPiece::SmallCorridorRightTurn { .. } => "minecraft:nescrt",
            FortressPiece::StalkRoom => "minecraft:necsr",
            FortressPiece::MonsterThrone { .. } => "minecraft:nemt",
            FortressPiece::RoomCrossing => "minecraft:nerc",
            FortressPiece::StairsRoom => "minecraft:nesr",
        }
    }

    pub fn save(&self, put: &mut dyn FnMut(&str, Nbt)) {
        match self {
            FortressPiece::BridgeEndFiller { seed } => put("Seed", Nbt::Int(*seed)),
            FortressPiece::SmallCorridorLeftTurn { chest }
            | FortressPiece::SmallCorridorRightTurn { chest } => put("Chest", Nbt::bool(*chest)),
            FortressPiece::MonsterThrone { spawner } => put("Mob", Nbt::bool(*spawner)),
            _ => {}
        }
    }
}

/// The weighted piece types: piece, weight, most placements (0: unlimited)
/// and whether it may follow itself.
const BRIDGE: [(Factory, i32, i32, bool); 6] = [
    (Factory::BridgeStraight, 30, 0, true),
    (Factory::BridgeCrossing, 10, 4, false),
    (Factory::RoomCrossing, 10, 4, false),
    (Factory::StairsRoom, 10, 3, false),
    (Factory::MonsterThrone, 5, 2, false),
    (Factory::Entrance, 5, 1, false),
];

const CASTLE: [(Factory, i32, i32, bool); 7] = [
    (Factory::SmallCorridor, 25, 0, true),
    (Factory::SmallCorridorCrossing, 15, 5, false),
    (Factory::SmallCorridorRightTurn, 5, 10, false),
    (Factory::SmallCorridorLeftTurn, 5, 10, false),
    (Factory::CorridorStairs, 10, 3, true),
    (Factory::CorridorTBalcony, 7, 2, false),
    (Factory::StalkRoom, 5, 2, false),
];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Factory {
    BridgeStraight,
    BridgeCrossing,
    RoomCrossing,
    StairsRoom,
    MonsterThrone,
    Entrance,
    SmallCorridor,
    SmallCorridorCrossing,
    SmallCorridorRightTurn,
    SmallCorridorLeftTurn,
    CorridorStairs,
    CorridorTBalcony,
    StalkRoom,
}

/// A weight's identity: castle list or not, and its index.
type WeightId = (bool, usize);

struct Layout<'a> {
    random: &'a mut Random,
    pieces: Vec<Piece>,
    bridge: Vec<usize>,
    castle: Vec<usize>,
    placed_bridge: [i32; 6],
    placed_castle: [i32; 7],
    previous: Option<WeightId>,
    pending: Vec<usize>,
    start_min: (i32, i32),
}

fn fortress(kind: FortressPiece, bbox: BoundingBox, direction: Direction, depth: i32) -> Piece {
    Piece {
        kind: PieceKind::Fortress(kind),
        bbox,
        orientation: Some(direction),
        gen_depth: depth,
    }
}

impl Layout<'_> {
    fn free_box(
        &self,
        foot: [i32; 3],
        offset: (i32, i32, i32),
        size: (i32, i32, i32),
        direction: Direction,
    ) -> Option<BoundingBox> {
        let b = BoundingBox::orient(
            (foot[0], foot[1], foot[2]),
            offset,
            size.0,
            size.1,
            size.2,
            direction,
        );
        (b.min_y > 10 && !self.pieces.iter().any(|p| p.bbox.intersects(&b))).then_some(b)
    }

    /// `findAndCreateBridgePieceFactory`.
    fn create(
        &mut self,
        factory: Factory,
        foot: [i32; 3],
        direction: Direction,
        depth: i32,
    ) -> Option<Piece> {
        use FortressPiece as F;
        let (kind, offset, size) = match factory {
            Factory::BridgeStraight => (F::BridgeStraight, (-1, -3, 0), (5, 10, 19)),
            Factory::BridgeCrossing => (F::BridgeCrossing, (-8, -3, 0), (19, 10, 19)),
            Factory::RoomCrossing => (F::RoomCrossing, (-2, 0, 0), (7, 9, 7)),
            Factory::StairsRoom => (F::StairsRoom, (-2, 0, 0), (7, 11, 7)),
            Factory::MonsterThrone => (F::MonsterThrone { spawner: false }, (-2, 0, 0), (7, 8, 9)),
            Factory::Entrance => (F::Entrance, (-5, -3, 0), (13, 14, 13)),
            Factory::SmallCorridor => (F::SmallCorridor, (-1, 0, 0), (5, 7, 5)),
            Factory::SmallCorridorCrossing => (F::SmallCorridorCrossing, (-1, 0, 0), (5, 7, 5)),
            Factory::SmallCorridorRightTurn => (
                F::SmallCorridorRightTurn { chest: false },
                (-1, 0, 0),
                (5, 7, 5),
            ),
            Factory::SmallCorridorLeftTurn => (
                F::SmallCorridorLeftTurn { chest: false },
                (-1, 0, 0),
                (5, 7, 5),
            ),
            Factory::CorridorStairs => (F::CorridorStairs, (-1, -7, 0), (5, 14, 10)),
            Factory::CorridorTBalcony => (F::CorridorTBalcony, (-3, 0, 0), (9, 7, 9)),
            Factory::StalkRoom => (F::StalkRoom, (-5, -3, 0), (13, 14, 13)),
        };
        let b = self.free_box(foot, offset, size, direction)?;
        let kind = match kind {
            F::SmallCorridorRightTurn { .. } => F::SmallCorridorRightTurn {
                chest: self.random.next_int_bounded(3) == 0,
            },
            F::SmallCorridorLeftTurn { .. } => F::SmallCorridorLeftTurn {
                chest: self.random.next_int_bounded(3) == 0,
            },
            other => other,
        };
        Some(fortress(kind, b, direction, depth))
    }

    /// `BridgeEndFiller.createPiece`.
    fn end_filler(&mut self, foot: [i32; 3], direction: Direction, depth: i32) -> Option<Piece> {
        let b = self.free_box(foot, (-1, -3, 0), (5, 10, 8), direction)?;
        let seed = self.random.next_int();
        Some(fortress(
            FortressPiece::BridgeEndFiller { seed },
            b,
            direction,
            depth,
        ))
    }

    /// `generatePiece` from the castle or bridge list.
    fn generate_piece(
        &mut self,
        castle: bool,
        foot: [i32; 3],
        direction: Direction,
        depth: i32,
    ) -> Option<Piece> {
        let weights: &[(Factory, i32, i32, bool)] = if castle { &CASTLE } else { &BRIDGE };
        let placed = |l: &Layout, w: usize| {
            if castle {
                l.placed_castle[w]
            } else {
                l.placed_bridge[w]
            }
        };
        let list = if castle { &self.castle } else { &self.bridge };
        let mut any = false;
        let mut total = 0;
        for &w in list {
            let (_, weight, max, _) = weights[w];
            if max > 0 && placed(self, w) < max {
                any = true;
            }
            total += weight;
        }
        let total = if any { total } else { -1 };
        if total > 0 && depth <= 30 {
            for _ in 0..5 {
                let mut selection = self.random.next_int_bounded(total);
                let mut i = 0;
                loop {
                    let list = if castle { &self.castle } else { &self.bridge };
                    if i >= list.len() {
                        break;
                    }
                    let w = list[i];
                    let (factory, weight, max, allow_in_row) = weights[w];
                    selection -= weight;
                    if selection < 0 {
                        let can = max == 0 || placed(self, w) < max;
                        if !can || (self.previous == Some((castle, w)) && !allow_in_row) {
                            break;
                        }
                        if let Some(piece) = self.create(factory, foot, direction, depth) {
                            let count = if castle {
                                &mut self.placed_castle[w]
                            } else {
                                &mut self.placed_bridge[w]
                            };
                            *count += 1;
                            let still = max == 0 || *count < max;
                            self.previous = Some((castle, w));
                            if !still {
                                if castle {
                                    self.castle.remove(i);
                                } else {
                                    self.bridge.remove(i);
                                }
                            }
                            return Some(piece);
                        }
                    }
                    i += 1;
                }
            }
        }
        self.end_filler(foot, direction, depth)
    }

    /// `generateAndAddPiece`; out of range, an end filler is made (drawing
    /// its seed) but not added, as in vanilla.
    fn add(&mut self, foot: [i32; 3], direction: Direction, depth: i32, castle: bool) {
        if (foot[0] - self.start_min.0).abs() <= 112 && (foot[2] - self.start_min.1).abs() <= 112 {
            if let Some(piece) = self.generate_piece(castle, foot, direction, depth + 1) {
                self.pieces.push(piece);
                self.pending.push(self.pieces.len() - 1);
            }
        } else {
            self.end_filler(foot, direction, depth);
        }
    }

    fn forward(&mut self, index: usize, x_off: i32, y_off: i32, castle: bool) {
        let p = &self.pieces[index];
        let (b, depth) = (p.bbox, p.gen_depth);
        let Some(o) = p.orientation else { return };
        let foot = match o {
            Direction::North => [b.min_x + x_off, b.min_y + y_off, b.min_z - 1],
            Direction::South => [b.min_x + x_off, b.min_y + y_off, b.max_z + 1],
            Direction::West => [b.min_x - 1, b.min_y + y_off, b.min_z + x_off],
            Direction::East => [b.max_x + 1, b.min_y + y_off, b.min_z + x_off],
        };
        self.add(foot, o, depth, castle);
    }

    fn left(&mut self, index: usize, y_off: i32, z_off: i32, castle: bool) {
        let p = &self.pieces[index];
        let (b, depth) = (p.bbox, p.gen_depth);
        let Some(o) = p.orientation else { return };
        let (foot, direction) = match o {
            Direction::North | Direction::South => (
                [b.min_x - 1, b.min_y + y_off, b.min_z + z_off],
                Direction::West,
            ),
            Direction::West | Direction::East => (
                [b.min_x + z_off, b.min_y + y_off, b.min_z - 1],
                Direction::North,
            ),
        };
        self.add(foot, direction, depth, castle);
    }

    fn right(&mut self, index: usize, y_off: i32, z_off: i32, castle: bool) {
        let p = &self.pieces[index];
        let (b, depth) = (p.bbox, p.gen_depth);
        let Some(o) = p.orientation else { return };
        let (foot, direction) = match o {
            Direction::North | Direction::South => (
                [b.max_x + 1, b.min_y + y_off, b.min_z + z_off],
                Direction::East,
            ),
            Direction::West | Direction::East => (
                [b.min_x + z_off, b.min_y + y_off, b.max_z + 1],
                Direction::South,
            ),
        };
        self.add(foot, direction, depth, castle);
    }

    fn add_children(&mut self, index: usize) {
        let PieceKind::Fortress(kind) = self.pieces[index].kind else {
            return;
        };
        let orientation = self.pieces[index].orientation;
        match kind {
            FortressPiece::BridgeCrossing => {
                self.forward(index, 8, 3, false);
                self.left(index, 3, 8, false);
                self.right(index, 3, 8, false);
            }
            FortressPiece::BridgeStraight => self.forward(index, 1, 3, false),
            FortressPiece::CorridorStairs | FortressPiece::SmallCorridor => {
                self.forward(index, 1, 0, true)
            }
            FortressPiece::CorridorTBalcony => {
                let z = if matches!(orientation, Some(Direction::West | Direction::North)) {
                    5
                } else {
                    1
                };
                let left = self.random.next_int_bounded(8) > 0;
                self.left(index, 0, z, left);
                let right = self.random.next_int_bounded(8) > 0;
                self.right(index, 0, z, right);
            }
            FortressPiece::Entrance => self.forward(index, 5, 3, true),
            FortressPiece::SmallCorridorCrossing => {
                self.forward(index, 1, 0, true);
                self.left(index, 0, 1, true);
                self.right(index, 0, 1, true);
            }
            FortressPiece::SmallCorridorLeftTurn { .. } => self.left(index, 0, 1, true),
            FortressPiece::SmallCorridorRightTurn { .. } => self.right(index, 0, 1, true),
            FortressPiece::StalkRoom => {
                self.forward(index, 5, 3, true);
                self.forward(index, 5, 11, true);
            }
            FortressPiece::RoomCrossing => {
                self.forward(index, 2, 0, false);
                self.left(index, 0, 2, false);
                self.right(index, 0, 2, false);
            }
            FortressPiece::StairsRoom => self.right(index, 6, 2, false),
            FortressPiece::BridgeEndFiller { .. } | FortressPiece::MonsterThrone { .. } => {}
        }
    }
}

/// `NetherFortressStructure.generatePieces`, after the biome check at the
/// chunk's corner at y 64.
pub fn generate(gc: &mut GenContext) -> Result<Option<Vec<Piece>>, String> {
    let (min_x, min_z) = (gc.min_block_x(), gc.min_block_z());
    if !gc.is_valid_biome((min_x, 64, min_z)) {
        return Ok(None);
    }
    let direction = Direction::random(&mut gc.random);
    let start = fortress(
        FortressPiece::BridgeCrossing,
        make_bounding_box(min_x + 2, 64, min_z + 2, direction, 19, 10, 19),
        direction,
        0,
    );
    let start_min = (start.bbox.min_x, start.bbox.min_z);
    let mut layout = Layout {
        random: &mut gc.random,
        pieces: vec![start],
        bridge: (0..BRIDGE.len()).collect(),
        castle: (0..CASTLE.len()).collect(),
        placed_bridge: [0; 6],
        placed_castle: [0; 7],
        previous: None,
        pending: Vec::new(),
        start_min,
    };
    layout.add_children(0);
    while !layout.pending.is_empty() {
        let pos = layout.random.next_int_bounded(layout.pending.len() as i32) as usize;
        let index = layout.pending.remove(pos);
        layout.add_children(index);
    }
    let mut pieces = layout.pieces;
    // `moveInsideHeights(random, 48, 70)`.
    let bb = encapsulating(pieces.iter().map(|p| &p.bbox)).expect("a start");
    let span = 70 - 48 + 1 - bb.y_span();
    let y0 = if span > 1 {
        48 + gc.random.next_int_bounded(span)
    } else {
        48
    };
    let dy = y0 - bb.min_y;
    for p in &mut pieces {
        p.moved_by(0, dy, 0);
    }
    Ok(Some(pieces))
}

// Placement (VMC-025f4): each piece's `postProcess`.

const FORTRESS_LOOT: &str = "minecraft:chests/nether_bridge";

/// A fortress piece's `postProcess`.
pub fn post_process(piece: &mut Piece, c: &mut Ctx) -> Result<(), String> {
    let PieceKind::Fortress(kind) = &mut piece.kind else {
        return Err("not a fortress piece".into());
    };
    let frame = Frame::new(piece.bbox, piece.orientation);
    let fr = &frame;
    let nether_bricks = c.state("nether_bricks")?;
    let air = c.state("air")?;
    let nether_brick_fence_north_true_south_true =
        c.state("nether_brick_fence[north=true,south=true]")?;
    let nether_brick_stairs_facing_south = c.state("nether_brick_stairs[facing=south]")?;
    let nether_brick_fence_west_true_east_true =
        c.state("nether_brick_fence[west=true,east=true]")?;
    let nether_brick_fence_east_true_south_true =
        c.state("nether_brick_fence[east=true,south=true]")?;
    let nether_brick_fence_west_true_south_true =
        c.state("nether_brick_fence[west=true,south=true]")?;
    let nether_brick_fence = c.state("nether_brick_fence")?;
    let nether_brick_fence_north_true_east_true =
        c.state("nether_brick_fence[north=true,east=true]")?;
    let nether_brick_fence_south_true_east_true =
        c.state("nether_brick_fence[south=true,east=true]")?;
    let nether_brick_fence_south_true_west_true =
        c.state("nether_brick_fence[south=true,west=true]")?;
    let nether_brick_fence_north_true_west_true =
        c.state("nether_brick_fence[north=true,west=true]")?;
    let lava = c.state("lava")?;
    let nether_brick_stairs_facing_north = c.state("nether_brick_stairs[facing=north]")?;
    let soul_sand = c.state("soul_sand")?;
    let nether_wart = c.state("nether_wart")?;
    let nether_brick_fence_west_true = c.state("nether_brick_fence[west=true]")?;
    let nether_brick_fence_east_true = c.state("nether_brick_fence[east=true]")?;
    let nether_brick_fence_east_true_north_true =
        c.state("nether_brick_fence[east=true,north=true]")?;
    let nether_brick_fence_west_true_north_true =
        c.state("nether_brick_fence[west=true,north=true]")?;
    match kind {
        FortressPiece::BridgeCrossing => {
            c.generate_box(
                fr,
                (7, 3, 0),
                (11, 4, 18),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 3, 7),
                (18, 4, 11),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (8, 5, 0), (10, 7, 18), air, air, false);
            c.generate_box(fr, (0, 5, 8), (18, 7, 10), air, air, false);
            c.generate_box(
                fr,
                (7, 5, 0),
                (7, 5, 7),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (7, 5, 11),
                (7, 5, 18),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (11, 5, 0),
                (11, 5, 7),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (11, 5, 11),
                (11, 5, 18),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 5, 7),
                (7, 5, 7),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (11, 5, 7),
                (18, 5, 7),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 5, 11),
                (7, 5, 11),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (11, 5, 11),
                (18, 5, 11),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (7, 2, 0),
                (11, 2, 5),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (7, 2, 13),
                (11, 2, 18),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (7, 0, 0),
                (11, 1, 3),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (7, 0, 15),
                (11, 1, 18),
                nether_bricks,
                nether_bricks,
                false,
            );
            for x in 7..=11 {
                for z in 0..=2 {
                    c.fill_column_down(fr, nether_bricks, x, -1, z);
                    c.fill_column_down(fr, nether_bricks, x, -1, 18 - z);
                }
            }
            c.generate_box(
                fr,
                (0, 2, 7),
                (5, 2, 11),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (13, 2, 7),
                (18, 2, 11),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 0, 7),
                (3, 1, 11),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (15, 0, 7),
                (18, 1, 11),
                nether_bricks,
                nether_bricks,
                false,
            );
            for x in 0..=2 {
                for z in 7..=11 {
                    c.fill_column_down(fr, nether_bricks, x, -1, z);
                    c.fill_column_down(fr, nether_bricks, 18 - x, -1, z);
                }
            }
        }
        FortressPiece::BridgeEndFiller { seed } => {
            let mut own = Random::legacy(*seed as i64);
            for x in 0..=4 {
                for y in 3..=4 {
                    let z = own.next_int_bounded(8);
                    c.generate_box(
                        fr,
                        (x, y, 0),
                        (x, y, z),
                        nether_bricks,
                        nether_bricks,
                        false,
                    );
                }
            }
            let z = own.next_int_bounded(8);
            c.generate_box(
                fr,
                (0, 5, 0),
                (0, 5, z),
                nether_bricks,
                nether_bricks,
                false,
            );
            let z = own.next_int_bounded(8);
            c.generate_box(
                fr,
                (4, 5, 0),
                (4, 5, z),
                nether_bricks,
                nether_bricks,
                false,
            );
            for x in 0..=4 {
                let z = own.next_int_bounded(5);
                c.generate_box(
                    fr,
                    (x, 2, 0),
                    (x, 2, z),
                    nether_bricks,
                    nether_bricks,
                    false,
                );
            }
            for x in 0..=4 {
                for y in 0..=1 {
                    let z = own.next_int_bounded(3);
                    c.generate_box(
                        fr,
                        (x, y, 0),
                        (x, y, z),
                        nether_bricks,
                        nether_bricks,
                        false,
                    );
                }
            }
        }
        FortressPiece::BridgeStraight => {
            c.generate_box(
                fr,
                (0, 3, 0),
                (4, 4, 18),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (1, 5, 0), (3, 7, 18), air, air, false);
            c.generate_box(
                fr,
                (0, 5, 0),
                (0, 5, 18),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (4, 5, 0),
                (4, 5, 18),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 2, 0),
                (4, 2, 5),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 2, 13),
                (4, 2, 18),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 0, 0),
                (4, 1, 3),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 0, 15),
                (4, 1, 18),
                nether_bricks,
                nether_bricks,
                false,
            );
            for x in 0..=4 {
                for z in 0..=2 {
                    c.fill_column_down(fr, nether_bricks, x, -1, z);
                    c.fill_column_down(fr, nether_bricks, x, -1, 18 - z);
                }
            }
            let ns_fence = nether_brick_fence_north_true_south_true;
            let nse_fence = c.placer.with(ns_fence, "east", "true");
            let nsw_fence = c.placer.with(ns_fence, "west", "true");
            c.generate_box(fr, (0, 1, 1), (0, 4, 1), nse_fence, nse_fence, false);
            c.generate_box(fr, (0, 3, 4), (0, 4, 4), nse_fence, nse_fence, false);
            c.generate_box(fr, (0, 3, 14), (0, 4, 14), nse_fence, nse_fence, false);
            c.generate_box(fr, (0, 1, 17), (0, 4, 17), nse_fence, nse_fence, false);
            c.generate_box(fr, (4, 1, 1), (4, 4, 1), nsw_fence, nsw_fence, false);
            c.generate_box(fr, (4, 3, 4), (4, 4, 4), nsw_fence, nsw_fence, false);
            c.generate_box(fr, (4, 3, 14), (4, 4, 14), nsw_fence, nsw_fence, false);
            c.generate_box(fr, (4, 1, 17), (4, 4, 17), nsw_fence, nsw_fence, false);
        }
        FortressPiece::CorridorStairs => {
            let stairs = nether_brick_stairs_facing_south;
            let ns_fence = nether_brick_fence_north_true_south_true;
            for step in 0..=9 {
                let floor = (1).max(7 - step);
                let roof = (floor + 5).max(14 - step).min(13);
                let z = step;
                c.generate_box(
                    fr,
                    (0, 0, z),
                    (4, floor, z),
                    nether_bricks,
                    nether_bricks,
                    false,
                );
                c.generate_box(fr, (1, floor + 1, z), (3, roof - 1, z), air, air, false);
                if step <= 6 {
                    c.place(fr, stairs, 1, floor + 1, z);
                    c.place(fr, stairs, 2, floor + 1, z);
                    c.place(fr, stairs, 3, floor + 1, z);
                }
                c.generate_box(
                    fr,
                    (0, roof, z),
                    (4, roof, z),
                    nether_bricks,
                    nether_bricks,
                    false,
                );
                c.generate_box(
                    fr,
                    (0, floor + 1, z),
                    (0, roof - 1, z),
                    nether_bricks,
                    nether_bricks,
                    false,
                );
                c.generate_box(
                    fr,
                    (4, floor + 1, z),
                    (4, roof - 1, z),
                    nether_bricks,
                    nether_bricks,
                    false,
                );
                if (step & 1) == 0 {
                    c.generate_box(
                        fr,
                        (0, floor + 2, z),
                        (0, floor + 3, z),
                        ns_fence,
                        ns_fence,
                        false,
                    );
                    c.generate_box(
                        fr,
                        (4, floor + 2, z),
                        (4, floor + 3, z),
                        ns_fence,
                        ns_fence,
                        false,
                    );
                }
                for x in 0..=4 {
                    c.fill_column_down(fr, nether_bricks, x, -1, z);
                }
            }
        }
        FortressPiece::CorridorTBalcony => {
            let ns_fence = nether_brick_fence_north_true_south_true;
            let we_fence = nether_brick_fence_west_true_east_true;
            c.generate_box(
                fr,
                (0, 0, 0),
                (8, 1, 8),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (0, 2, 0), (8, 5, 8), air, air, false);
            c.generate_box(
                fr,
                (0, 6, 0),
                (8, 6, 5),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 2, 0),
                (2, 5, 0),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (6, 2, 0),
                (8, 5, 0),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (1, 3, 0), (1, 4, 0), we_fence, we_fence, false);
            c.generate_box(fr, (7, 3, 0), (7, 4, 0), we_fence, we_fence, false);
            c.generate_box(
                fr,
                (0, 2, 4),
                (8, 2, 8),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (1, 1, 4), (2, 2, 4), air, air, false);
            c.generate_box(fr, (6, 1, 4), (7, 2, 4), air, air, false);
            c.generate_box(fr, (1, 3, 8), (7, 3, 8), we_fence, we_fence, false);
            c.place(fr, nether_brick_fence_east_true_south_true, 0, 3, 8);
            c.place(fr, nether_brick_fence_west_true_south_true, 8, 3, 8);
            c.generate_box(fr, (0, 3, 6), (0, 3, 7), ns_fence, ns_fence, false);
            c.generate_box(fr, (8, 3, 6), (8, 3, 7), ns_fence, ns_fence, false);
            c.generate_box(
                fr,
                (0, 3, 4),
                (0, 5, 5),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (8, 3, 4),
                (8, 5, 5),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (1, 3, 5),
                (2, 5, 5),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (6, 3, 5),
                (7, 5, 5),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (1, 4, 5), (1, 5, 5), we_fence, we_fence, false);
            c.generate_box(fr, (7, 4, 5), (7, 5, 5), we_fence, we_fence, false);
            for z in 0..=5 {
                for x in 0..=8 {
                    c.fill_column_down(fr, nether_bricks, x, -1, z);
                }
            }
        }
        FortressPiece::Entrance => {
            c.generate_box(
                fr,
                (0, 3, 0),
                (12, 4, 12),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (0, 5, 0), (12, 13, 12), air, air, false);
            c.generate_box(
                fr,
                (0, 5, 0),
                (1, 12, 12),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (11, 5, 0),
                (12, 12, 12),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (2, 5, 11),
                (4, 12, 12),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (8, 5, 11),
                (10, 12, 12),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (5, 9, 11),
                (7, 12, 12),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (2, 5, 0),
                (4, 12, 1),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (8, 5, 0),
                (10, 12, 1),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (5, 9, 0),
                (7, 12, 1),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (2, 11, 2),
                (10, 12, 10),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (5, 8, 0),
                (7, 8, 0),
                nether_brick_fence,
                nether_brick_fence,
                false,
            );
            let we_fence = nether_brick_fence_west_true_east_true;
            let ns_fence = nether_brick_fence_north_true_south_true;
            for i in (1..=11).step_by(2) {
                c.generate_box(fr, (i, 10, 0), (i, 11, 0), we_fence, we_fence, false);
                c.generate_box(fr, (i, 10, 12), (i, 11, 12), we_fence, we_fence, false);
                c.generate_box(fr, (0, 10, i), (0, 11, i), ns_fence, ns_fence, false);
                c.generate_box(fr, (12, 10, i), (12, 11, i), ns_fence, ns_fence, false);
                c.place(fr, nether_bricks, i, 13, 0);
                c.place(fr, nether_bricks, i, 13, 12);
                c.place(fr, nether_bricks, 0, 13, i);
                c.place(fr, nether_bricks, 12, 13, i);
                if i != 11 {
                    c.place(fr, we_fence, i + 1, 13, 0);
                    c.place(fr, we_fence, i + 1, 13, 12);
                    c.place(fr, ns_fence, 0, 13, i + 1);
                    c.place(fr, ns_fence, 12, 13, i + 1);
                }
            }
            c.place(fr, nether_brick_fence_north_true_east_true, 0, 13, 0);
            c.place(fr, nether_brick_fence_south_true_east_true, 0, 13, 12);
            c.place(fr, nether_brick_fence_south_true_west_true, 12, 13, 12);
            c.place(fr, nether_brick_fence_north_true_west_true, 12, 13, 0);
            for z in (3..=9).step_by(2) {
                c.generate_box(
                    fr,
                    (1, 7, z),
                    (1, 8, z),
                    c.placer.with(ns_fence, "west", "true"),
                    c.placer.with(ns_fence, "west", "true"),
                    false,
                );
                c.generate_box(
                    fr,
                    (11, 7, z),
                    (11, 8, z),
                    c.placer.with(ns_fence, "east", "true"),
                    c.placer.with(ns_fence, "east", "true"),
                    false,
                );
            }
            c.generate_box(
                fr,
                (4, 2, 0),
                (8, 2, 12),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 2, 4),
                (12, 2, 8),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (4, 0, 0),
                (8, 1, 3),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (4, 0, 9),
                (8, 1, 12),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 0, 4),
                (3, 1, 8),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (9, 0, 4),
                (12, 1, 8),
                nether_bricks,
                nether_bricks,
                false,
            );
            for x in 4..=8 {
                for z in 0..=2 {
                    c.fill_column_down(fr, nether_bricks, x, -1, z);
                    c.fill_column_down(fr, nether_bricks, x, -1, 12 - z);
                }
            }
            for x in 0..=2 {
                for z in 4..=8 {
                    c.fill_column_down(fr, nether_bricks, x, -1, z);
                    c.fill_column_down(fr, nether_bricks, 12 - x, -1, z);
                }
            }
            c.generate_box(
                fr,
                (5, 5, 5),
                (7, 5, 7),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (6, 1, 6), (6, 4, 6), air, air, false);
            c.place(fr, nether_bricks, 6, 0, 6);
            c.place(fr, lava, 6, 5, 6);
            let pos = fr.world(6, 5, 6);
            if c.chunk_box.is_inside(pos[0], pos[1], pos[2]) {
                c.region.schedule_fluid_tick(pos, FLUID_LAVA);
            }
        }
        FortressPiece::SmallCorridorCrossing => {
            c.generate_box(
                fr,
                (0, 0, 0),
                (4, 1, 4),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (0, 2, 0), (4, 5, 4), air, air, false);
            c.generate_box(
                fr,
                (0, 2, 0),
                (0, 5, 0),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (4, 2, 0),
                (4, 5, 0),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 2, 4),
                (0, 5, 4),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (4, 2, 4),
                (4, 5, 4),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 6, 0),
                (4, 6, 4),
                nether_bricks,
                nether_bricks,
                false,
            );
            for x in 0..=4 {
                for z in 0..=4 {
                    c.fill_column_down(fr, nether_bricks, x, -1, z);
                }
            }
        }
        FortressPiece::SmallCorridorLeftTurn { chest } => {
            c.generate_box(
                fr,
                (0, 0, 0),
                (4, 1, 4),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (0, 2, 0), (4, 5, 4), air, air, false);
            let we_fence = nether_brick_fence_west_true_east_true;
            let ns_fence = nether_brick_fence_north_true_south_true;
            c.generate_box(
                fr,
                (4, 2, 0),
                (4, 5, 4),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (4, 3, 1), (4, 4, 1), ns_fence, ns_fence, false);
            c.generate_box(fr, (4, 3, 3), (4, 4, 3), ns_fence, ns_fence, false);
            c.generate_box(
                fr,
                (0, 2, 0),
                (0, 5, 0),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 2, 4),
                (3, 5, 4),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (1, 3, 4), (1, 4, 4), we_fence, we_fence, false);
            c.generate_box(fr, (3, 3, 4), (3, 4, 4), we_fence, we_fence, false);
            let at = fr.world(3, 2, 3);
            if *chest && c.chunk_box.is_inside(at[0], at[1], at[2]) {
                *chest = false;
                c.create_chest_at(fr, 3, 2, 3, FORTRESS_LOOT)?;
            }
            c.generate_box(
                fr,
                (0, 6, 0),
                (4, 6, 4),
                nether_bricks,
                nether_bricks,
                false,
            );
            for x in 0..=4 {
                for z in 0..=4 {
                    c.fill_column_down(fr, nether_bricks, x, -1, z);
                }
            }
        }
        FortressPiece::SmallCorridor => {
            c.generate_box(
                fr,
                (0, 0, 0),
                (4, 1, 4),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (0, 2, 0), (4, 5, 4), air, air, false);
            let ns_fence = nether_brick_fence_north_true_south_true;
            c.generate_box(
                fr,
                (0, 2, 0),
                (0, 5, 4),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (4, 2, 0),
                (4, 5, 4),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (0, 3, 1), (0, 4, 1), ns_fence, ns_fence, false);
            c.generate_box(fr, (0, 3, 3), (0, 4, 3), ns_fence, ns_fence, false);
            c.generate_box(fr, (4, 3, 1), (4, 4, 1), ns_fence, ns_fence, false);
            c.generate_box(fr, (4, 3, 3), (4, 4, 3), ns_fence, ns_fence, false);
            c.generate_box(
                fr,
                (0, 6, 0),
                (4, 6, 4),
                nether_bricks,
                nether_bricks,
                false,
            );
            for x in 0..=4 {
                for z in 0..=4 {
                    c.fill_column_down(fr, nether_bricks, x, -1, z);
                }
            }
        }
        FortressPiece::SmallCorridorRightTurn { chest } => {
            c.generate_box(
                fr,
                (0, 0, 0),
                (4, 1, 4),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (0, 2, 0), (4, 5, 4), air, air, false);
            let we_fence = nether_brick_fence_west_true_east_true;
            let ns_fence = nether_brick_fence_north_true_south_true;
            c.generate_box(
                fr,
                (0, 2, 0),
                (0, 5, 4),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (0, 3, 1), (0, 4, 1), ns_fence, ns_fence, false);
            c.generate_box(fr, (0, 3, 3), (0, 4, 3), ns_fence, ns_fence, false);
            c.generate_box(
                fr,
                (4, 2, 0),
                (4, 5, 0),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (1, 2, 4),
                (4, 5, 4),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (1, 3, 4), (1, 4, 4), we_fence, we_fence, false);
            c.generate_box(fr, (3, 3, 4), (3, 4, 4), we_fence, we_fence, false);
            let at = fr.world(1, 2, 3);
            if *chest && c.chunk_box.is_inside(at[0], at[1], at[2]) {
                *chest = false;
                c.create_chest_at(fr, 1, 2, 3, FORTRESS_LOOT)?;
            }
            c.generate_box(
                fr,
                (0, 6, 0),
                (4, 6, 4),
                nether_bricks,
                nether_bricks,
                false,
            );
            for x in 0..=4 {
                for z in 0..=4 {
                    c.fill_column_down(fr, nether_bricks, x, -1, z);
                }
            }
        }
        FortressPiece::StalkRoom => {
            c.generate_box(
                fr,
                (0, 3, 0),
                (12, 4, 12),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (0, 5, 0), (12, 13, 12), air, air, false);
            c.generate_box(
                fr,
                (0, 5, 0),
                (1, 12, 12),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (11, 5, 0),
                (12, 12, 12),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (2, 5, 11),
                (4, 12, 12),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (8, 5, 11),
                (10, 12, 12),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (5, 9, 11),
                (7, 12, 12),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (2, 5, 0),
                (4, 12, 1),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (8, 5, 0),
                (10, 12, 1),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (5, 9, 0),
                (7, 12, 1),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (2, 11, 2),
                (10, 12, 10),
                nether_bricks,
                nether_bricks,
                false,
            );
            let we_fence = nether_brick_fence_west_true_east_true;
            let ns_fence = nether_brick_fence_north_true_south_true;
            let nsw_fence = c.placer.with(ns_fence, "west", "true");
            let nse_fence = c.placer.with(ns_fence, "east", "true");
            for i in (1..=11).step_by(2) {
                c.generate_box(fr, (i, 10, 0), (i, 11, 0), we_fence, we_fence, false);
                c.generate_box(fr, (i, 10, 12), (i, 11, 12), we_fence, we_fence, false);
                c.generate_box(fr, (0, 10, i), (0, 11, i), ns_fence, ns_fence, false);
                c.generate_box(fr, (12, 10, i), (12, 11, i), ns_fence, ns_fence, false);
                c.place(fr, nether_bricks, i, 13, 0);
                c.place(fr, nether_bricks, i, 13, 12);
                c.place(fr, nether_bricks, 0, 13, i);
                c.place(fr, nether_bricks, 12, 13, i);
                if i != 11 {
                    c.place(fr, we_fence, i + 1, 13, 0);
                    c.place(fr, we_fence, i + 1, 13, 12);
                    c.place(fr, ns_fence, 0, 13, i + 1);
                    c.place(fr, ns_fence, 12, 13, i + 1);
                }
            }
            c.place(fr, nether_brick_fence_north_true_east_true, 0, 13, 0);
            c.place(fr, nether_brick_fence_south_true_east_true, 0, 13, 12);
            c.place(fr, nether_brick_fence_south_true_west_true, 12, 13, 12);
            c.place(fr, nether_brick_fence_north_true_west_true, 12, 13, 0);
            for z in (3..=9).step_by(2) {
                c.generate_box(fr, (1, 7, z), (1, 8, z), nsw_fence, nsw_fence, false);
                c.generate_box(fr, (11, 7, z), (11, 8, z), nse_fence, nse_fence, false);
            }
            let stairs = nether_brick_stairs_facing_north;
            for i in 0..=6 {
                let z = i + 4;
                for x in 5..=7 {
                    c.place(fr, stairs, x, 5 + i, z);
                }
                if (5..=8).contains(&z) {
                    c.generate_box(
                        fr,
                        (5, 5, z),
                        (7, i + 4, z),
                        nether_bricks,
                        nether_bricks,
                        false,
                    );
                } else if (9..=10).contains(&z) {
                    c.generate_box(
                        fr,
                        (5, 8, z),
                        (7, i + 4, z),
                        nether_bricks,
                        nether_bricks,
                        false,
                    );
                }
                if i >= 1 {
                    c.generate_box(fr, (5, 6 + i, z), (7, 9 + i, z), air, air, false);
                }
            }
            for x in 5..=7 {
                c.place(fr, stairs, x, 12, 11);
            }
            c.generate_box(fr, (5, 6, 7), (5, 7, 7), nse_fence, nse_fence, false);
            c.generate_box(fr, (7, 6, 7), (7, 7, 7), nsw_fence, nsw_fence, false);
            c.generate_box(fr, (5, 13, 12), (7, 13, 12), air, air, false);
            c.generate_box(
                fr,
                (2, 5, 2),
                (3, 5, 3),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (2, 5, 9),
                (3, 5, 10),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (2, 5, 4),
                (2, 5, 8),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (9, 5, 2),
                (10, 5, 3),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (9, 5, 9),
                (10, 5, 10),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (10, 5, 4),
                (10, 5, 8),
                nether_bricks,
                nether_bricks,
                false,
            );
            let east_stairs = c.placer.with(stairs, "facing", "east");
            let west_stairs = c.placer.with(stairs, "facing", "west");
            c.place(fr, west_stairs, 4, 5, 2);
            c.place(fr, west_stairs, 4, 5, 3);
            c.place(fr, west_stairs, 4, 5, 9);
            c.place(fr, west_stairs, 4, 5, 10);
            c.place(fr, east_stairs, 8, 5, 2);
            c.place(fr, east_stairs, 8, 5, 3);
            c.place(fr, east_stairs, 8, 5, 9);
            c.place(fr, east_stairs, 8, 5, 10);
            c.generate_box(fr, (3, 4, 4), (4, 4, 8), soul_sand, soul_sand, false);
            c.generate_box(fr, (8, 4, 4), (9, 4, 8), soul_sand, soul_sand, false);
            c.generate_box(fr, (3, 5, 4), (4, 5, 8), nether_wart, nether_wart, false);
            c.generate_box(fr, (8, 5, 4), (9, 5, 8), nether_wart, nether_wart, false);
            c.generate_box(
                fr,
                (4, 2, 0),
                (8, 2, 12),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 2, 4),
                (12, 2, 8),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (4, 0, 0),
                (8, 1, 3),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (4, 0, 9),
                (8, 1, 12),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 0, 4),
                (3, 1, 8),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (9, 0, 4),
                (12, 1, 8),
                nether_bricks,
                nether_bricks,
                false,
            );
            for x in 4..=8 {
                for z in 0..=2 {
                    c.fill_column_down(fr, nether_bricks, x, -1, z);
                    c.fill_column_down(fr, nether_bricks, x, -1, 12 - z);
                }
            }
            for x in 0..=2 {
                for z in 4..=8 {
                    c.fill_column_down(fr, nether_bricks, x, -1, z);
                    c.fill_column_down(fr, nether_bricks, 12 - x, -1, z);
                }
            }
        }
        FortressPiece::MonsterThrone { spawner } => {
            c.generate_box(fr, (0, 2, 0), (6, 7, 7), air, air, false);
            c.generate_box(
                fr,
                (1, 0, 0),
                (5, 1, 7),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (1, 2, 1),
                (5, 2, 7),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (1, 3, 2),
                (5, 3, 7),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (1, 4, 3),
                (5, 4, 7),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (1, 2, 0),
                (1, 4, 2),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (5, 2, 0),
                (5, 4, 2),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (1, 5, 2),
                (1, 5, 3),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (5, 5, 2),
                (5, 5, 3),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 5, 3),
                (0, 5, 8),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (6, 5, 3),
                (6, 5, 8),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (1, 5, 8),
                (5, 5, 8),
                nether_bricks,
                nether_bricks,
                false,
            );
            let we_fence = nether_brick_fence_west_true_east_true;
            let ns_fence = nether_brick_fence_north_true_south_true;
            c.place(fr, nether_brick_fence_west_true, 1, 6, 3);
            c.place(fr, nether_brick_fence_east_true, 5, 6, 3);
            c.place(fr, nether_brick_fence_east_true_north_true, 0, 6, 3);
            c.place(fr, nether_brick_fence_west_true_north_true, 6, 6, 3);
            c.generate_box(fr, (0, 6, 4), (0, 6, 7), ns_fence, ns_fence, false);
            c.generate_box(fr, (6, 6, 4), (6, 6, 7), ns_fence, ns_fence, false);
            c.place(fr, nether_brick_fence_east_true_south_true, 0, 6, 8);
            c.place(fr, nether_brick_fence_west_true_south_true, 6, 6, 8);
            c.generate_box(fr, (1, 6, 8), (5, 6, 8), we_fence, we_fence, false);
            c.place(fr, nether_brick_fence_east_true, 1, 7, 8);
            c.generate_box(fr, (2, 7, 8), (4, 7, 8), we_fence, we_fence, false);
            c.place(fr, nether_brick_fence_west_true, 5, 7, 8);
            c.place(fr, nether_brick_fence_east_true, 2, 8, 8);
            c.place(fr, we_fence, 3, 8, 8);
            c.place(fr, nether_brick_fence_west_true, 4, 8, 8);
            let pos = fr.world(3, 5, 5);
            if !*spawner && c.chunk_box.is_inside(pos[0], pos[1], pos[2]) {
                *spawner = true;
                let state = c.state("spawner")?;
                c.set(pos, state, 2);
                if let Some(entity) = c.region.block_entity(pos)? {
                    if entity.kind == "minecraft:mob_spawner" {
                        entity.spawner_entity = Some("minecraft:blaze".into());
                    }
                }
            }
            for x in 0..=6 {
                for z in 0..=6 {
                    c.fill_column_down(fr, nether_bricks, x, -1, z);
                }
            }
        }
        FortressPiece::RoomCrossing => {
            c.generate_box(
                fr,
                (0, 0, 0),
                (6, 1, 6),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (0, 2, 0), (6, 7, 6), air, air, false);
            c.generate_box(
                fr,
                (0, 2, 0),
                (1, 6, 0),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 2, 6),
                (1, 6, 6),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (5, 2, 0),
                (6, 6, 0),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (5, 2, 6),
                (6, 6, 6),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 2, 0),
                (0, 6, 1),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 2, 5),
                (0, 6, 6),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (6, 2, 0),
                (6, 6, 1),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (6, 2, 5),
                (6, 6, 6),
                nether_bricks,
                nether_bricks,
                false,
            );
            let we_fence = nether_brick_fence_west_true_east_true;
            let ns_fence = nether_brick_fence_north_true_south_true;
            c.generate_box(
                fr,
                (2, 6, 0),
                (4, 6, 0),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (2, 5, 0), (4, 5, 0), we_fence, we_fence, false);
            c.generate_box(
                fr,
                (2, 6, 6),
                (4, 6, 6),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (2, 5, 6), (4, 5, 6), we_fence, we_fence, false);
            c.generate_box(
                fr,
                (0, 6, 2),
                (0, 6, 4),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (0, 5, 2), (0, 5, 4), ns_fence, ns_fence, false);
            c.generate_box(
                fr,
                (6, 6, 2),
                (6, 6, 4),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (6, 5, 2), (6, 5, 4), ns_fence, ns_fence, false);
            for x in 0..=6 {
                for z in 0..=6 {
                    c.fill_column_down(fr, nether_bricks, x, -1, z);
                }
            }
        }
        FortressPiece::StairsRoom => {
            c.generate_box(
                fr,
                (0, 0, 0),
                (6, 1, 6),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (0, 2, 0), (6, 10, 6), air, air, false);
            c.generate_box(
                fr,
                (0, 2, 0),
                (1, 8, 0),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (5, 2, 0),
                (6, 8, 0),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (0, 2, 1),
                (0, 8, 6),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (6, 2, 1),
                (6, 8, 6),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (1, 2, 6),
                (5, 8, 6),
                nether_bricks,
                nether_bricks,
                false,
            );
            let we_fence = nether_brick_fence_west_true_east_true;
            let ns_fence = nether_brick_fence_north_true_south_true;
            c.generate_box(fr, (0, 3, 2), (0, 5, 4), ns_fence, ns_fence, false);
            c.generate_box(fr, (6, 3, 2), (6, 5, 2), ns_fence, ns_fence, false);
            c.generate_box(fr, (6, 3, 4), (6, 5, 4), ns_fence, ns_fence, false);
            c.place(fr, nether_bricks, 5, 2, 5);
            c.generate_box(
                fr,
                (4, 2, 5),
                (4, 3, 5),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (3, 2, 5),
                (3, 4, 5),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (2, 2, 5),
                (2, 5, 5),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (1, 2, 5),
                (1, 6, 5),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(
                fr,
                (1, 7, 1),
                (5, 7, 4),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (6, 8, 2), (6, 8, 4), air, air, false);
            c.generate_box(
                fr,
                (2, 6, 0),
                (4, 8, 0),
                nether_bricks,
                nether_bricks,
                false,
            );
            c.generate_box(fr, (2, 5, 0), (4, 5, 0), we_fence, we_fence, false);
            for x in 0..=6 {
                for z in 0..=6 {
                    c.fill_column_down(fr, nether_bricks, x, -1, z);
                }
            }
        }
    }
    Ok(())
}
