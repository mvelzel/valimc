//! Nether fortresses (VMC-025e4, `NetherFortressStructure`,
//! `NetherFortressPieces`): a bridge crossing at y 64 growing bridges and
//! castle corridors from two weighted piece lists (pending children in random
//! order, end fillers where nothing fits), then moved to between y 48 and 70.
//! Vanilla's start piece is a bridge crossing and saves as one.

use super::super::random::Random;
use super::piece::{
    encapsulating, make_bounding_box, BoundingBox, Direction, Nbt, Piece, PieceKind,
};
use super::GenContext;

/// A fortress piece's type and own fields.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum FortressPiece {
    BridgeCrossing,
    BridgeEndFiller { seed: i32 },
    BridgeStraight,
    CorridorStairs,
    CorridorTBalcony,
    Entrance,
    SmallCorridorCrossing,
    SmallCorridorLeftTurn { chest: bool },
    SmallCorridor,
    SmallCorridorRightTurn { chest: bool },
    StalkRoom,
    MonsterThrone,
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
            FortressPiece::MonsterThrone => "minecraft:nemt",
            FortressPiece::RoomCrossing => "minecraft:nerc",
            FortressPiece::StairsRoom => "minecraft:nesr",
        }
    }

    pub fn save(&self, put: &mut dyn FnMut(&str, Nbt)) {
        match self {
            FortressPiece::BridgeEndFiller { seed } => put("Seed", Nbt::Int(*seed)),
            FortressPiece::SmallCorridorLeftTurn { chest }
            | FortressPiece::SmallCorridorRightTurn { chest } => put("Chest", Nbt::bool(*chest)),
            FortressPiece::MonsterThrone => put("Mob", Nbt::bool(false)),
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
            Factory::MonsterThrone => (F::MonsterThrone, (-2, 0, 0), (7, 8, 9)),
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
            FortressPiece::BridgeEndFiller { .. } | FortressPiece::MonsterThrone => {}
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
