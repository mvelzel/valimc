//! Strongholds (VMC-025e4, `StrongholdStructure`, `StrongholdPieces`): a
//! staircase start at y 64 whose doors grow corridors, turns, crossings,
//! rooms, a library and the portal room from a weighted piece list (pending
//! children taken in random order), regenerated from the next seed until a
//! portal room exists, then moved below sea level.

use super::super::carver::set_large_feature_seed;
use super::super::random::Random;
use super::piece::{
    encapsulating, make_bounding_box, BoundingBox, Direction, Nbt, Piece, PieceKind,
};
use super::GenContext;

/// `SmallDoorType`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Door {
    Opening,
    WoodDoor,
    Grates,
    IronDoor,
}

impl Door {
    fn name(self) -> &'static str {
        match self {
            Door::Opening => "OPENING",
            Door::WoodDoor => "WOOD_DOOR",
            Door::Grates => "GRATES",
            Door::IronDoor => "IRON_DOOR",
        }
    }

    /// `randomSmallDoor`.
    fn random(random: &mut Random) -> Door {
        match random.next_int_bounded(5) {
            2 => Door::WoodDoor,
            3 => Door::Grates,
            4 => Door::IronDoor,
            _ => Door::Opening,
        }
    }
}

/// A stronghold piece's type and own fields.
#[derive(Clone, Debug, PartialEq)]
pub enum StrongholdKind {
    Start,
    Straight {
        left: bool,
        right: bool,
    },
    PrisonHall,
    LeftTurn,
    RightTurn,
    RoomCrossing {
        kind: i32,
    },
    StraightStairsDown,
    StairsDown,
    FiveCrossing {
        left_low: bool,
        left_high: bool,
        right_low: bool,
        right_high: bool,
    },
    ChestCorridor,
    Library {
        tall: bool,
    },
    PortalRoom,
    FillerCorridor {
        steps: i32,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct StrongholdPiece {
    pub kind: StrongholdKind,
    pub entry_door: Door,
}

impl StrongholdPiece {
    pub fn id(&self) -> &'static str {
        match self.kind {
            StrongholdKind::Start => "minecraft:shstart",
            StrongholdKind::Straight { .. } => "minecraft:shs",
            StrongholdKind::PrisonHall => "minecraft:shph",
            StrongholdKind::LeftTurn => "minecraft:shlt",
            StrongholdKind::RightTurn => "minecraft:shrt",
            StrongholdKind::RoomCrossing { .. } => "minecraft:shrc",
            StrongholdKind::StraightStairsDown => "minecraft:shssd",
            StrongholdKind::StairsDown => "minecraft:shsd",
            StrongholdKind::FiveCrossing { .. } => "minecraft:sh5c",
            StrongholdKind::ChestCorridor => "minecraft:shcc",
            StrongholdKind::Library { .. } => "minecraft:shli",
            StrongholdKind::PortalRoom => "minecraft:shpr",
            StrongholdKind::FillerCorridor { .. } => "minecraft:shfc",
        }
    }

    pub fn save(&self, put: &mut dyn FnMut(&str, Nbt)) {
        put("EntryDoor", Nbt::string(self.entry_door.name()));
        match self.kind {
            StrongholdKind::Start => put("Source", Nbt::bool(true)),
            StrongholdKind::StairsDown => put("Source", Nbt::bool(false)),
            StrongholdKind::Straight { left, right } => {
                put("Left", Nbt::bool(left));
                put("Right", Nbt::bool(right));
            }
            StrongholdKind::RoomCrossing { kind } => put("Type", Nbt::Int(kind)),
            StrongholdKind::FiveCrossing {
                left_low,
                left_high,
                right_low,
                right_high,
            } => {
                put("leftLow", Nbt::bool(left_low));
                put("leftHigh", Nbt::bool(left_high));
                put("rightLow", Nbt::bool(right_low));
                put("rightHigh", Nbt::bool(right_high));
            }
            StrongholdKind::ChestCorridor => put("Chest", Nbt::bool(false)),
            StrongholdKind::Library { tall } => put("Tall", Nbt::bool(tall)),
            StrongholdKind::PortalRoom => put("Mob", Nbt::bool(false)),
            StrongholdKind::FillerCorridor { steps } => put("Steps", Nbt::Int(steps)),
            StrongholdKind::PrisonHall
            | StrongholdKind::LeftTurn
            | StrongholdKind::RightTurn
            | StrongholdKind::StraightStairsDown => {}
        }
    }
}

/// The weighted piece types (`STRONGHOLD_PIECE_WEIGHTS`): weight and most
/// placements (0: unlimited).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Factory {
    Straight,
    PrisonHall,
    LeftTurn,
    RightTurn,
    RoomCrossing,
    StraightStairsDown,
    StairsDown,
    FiveCrossing,
    ChestCorridor,
    Library,
    PortalRoom,
}

const WEIGHTS: [(Factory, i32, i32); 11] = [
    (Factory::Straight, 40, 0),
    (Factory::PrisonHall, 5, 5),
    (Factory::LeftTurn, 20, 0),
    (Factory::RightTurn, 20, 0),
    (Factory::RoomCrossing, 10, 6),
    (Factory::StraightStairsDown, 5, 5),
    (Factory::StairsDown, 5, 5),
    (Factory::FiveCrossing, 5, 4),
    (Factory::ChestCorridor, 5, 4),
    (Factory::Library, 10, 2),
    (Factory::PortalRoom, 20, 1),
];

struct Layout<'a> {
    random: &'a mut Random,
    pieces: Vec<Piece>,
    /// Indices into `WEIGHTS` still in play, and per weight its placements.
    current: Vec<usize>,
    placed: [i32; 11],
    total_weight: i32,
    imposed: Option<Factory>,
    previous: Option<usize>,
    portal_room: bool,
    pending: Vec<usize>,
    start_min: (i32, i32),
}

fn sh(
    kind: StrongholdKind,
    door: Door,
    bbox: BoundingBox,
    direction: Direction,
    depth: i32,
) -> Piece {
    Piece {
        kind: PieceKind::Stronghold(StrongholdPiece {
            kind,
            entry_door: door,
        }),
        bbox,
        orientation: Some(direction),
        gen_depth: depth,
    }
}

impl Layout<'_> {
    fn collides(&self, b: &BoundingBox) -> bool {
        self.pieces.iter().any(|p| p.bbox.intersects(b))
    }

    /// A piece's box when it is above y 10 and meets no other piece.
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
        (b.min_y > 10 && !self.collides(&b)).then_some(b)
    }

    /// `findAndCreatePieceFactory`.
    fn create(
        &mut self,
        factory: Factory,
        foot: [i32; 3],
        direction: Direction,
        depth: i32,
    ) -> Option<Piece> {
        use StrongholdKind as K;
        let small = (-1, -1, 0);
        Some(match factory {
            Factory::Straight => {
                let b = self.free_box(foot, small, (5, 5, 7), direction)?;
                let door = Door::random(self.random);
                let left = self.random.next_int_bounded(2) == 0;
                let right = self.random.next_int_bounded(2) == 0;
                sh(K::Straight { left, right }, door, b, direction, depth)
            }
            Factory::PrisonHall => {
                let b = self.free_box(foot, small, (9, 5, 11), direction)?;
                sh(
                    K::PrisonHall,
                    Door::random(self.random),
                    b,
                    direction,
                    depth,
                )
            }
            Factory::LeftTurn => {
                let b = self.free_box(foot, small, (5, 5, 5), direction)?;
                sh(K::LeftTurn, Door::random(self.random), b, direction, depth)
            }
            Factory::RightTurn => {
                let b = self.free_box(foot, small, (5, 5, 5), direction)?;
                sh(K::RightTurn, Door::random(self.random), b, direction, depth)
            }
            Factory::RoomCrossing => {
                let b = self.free_box(foot, (-4, -1, 0), (11, 7, 11), direction)?;
                let door = Door::random(self.random);
                let kind = self.random.next_int_bounded(5);
                sh(K::RoomCrossing { kind }, door, b, direction, depth)
            }
            Factory::StraightStairsDown => {
                let b = self.free_box(foot, (-1, -7, 0), (5, 11, 8), direction)?;
                sh(
                    K::StraightStairsDown,
                    Door::random(self.random),
                    b,
                    direction,
                    depth,
                )
            }
            Factory::StairsDown => {
                let b = self.free_box(foot, (-1, -7, 0), (5, 11, 5), direction)?;
                sh(
                    K::StairsDown,
                    Door::random(self.random),
                    b,
                    direction,
                    depth,
                )
            }
            Factory::FiveCrossing => {
                let b = self.free_box(foot, (-4, -3, 0), (10, 9, 11), direction)?;
                let door = Door::random(self.random);
                let left_low = self.random.next_bool();
                let left_high = self.random.next_bool();
                let right_low = self.random.next_bool();
                let right_high = self.random.next_int_bounded(3) > 0;
                sh(
                    K::FiveCrossing {
                        left_low,
                        left_high,
                        right_low,
                        right_high,
                    },
                    door,
                    b,
                    direction,
                    depth,
                )
            }
            Factory::ChestCorridor => {
                let b = self.free_box(foot, small, (5, 5, 7), direction)?;
                sh(
                    K::ChestCorridor,
                    Door::random(self.random),
                    b,
                    direction,
                    depth,
                )
            }
            Factory::Library => {
                let b = self
                    .free_box(foot, (-4, -1, 0), (14, 11, 15), direction)
                    .or_else(|| self.free_box(foot, (-4, -1, 0), (14, 6, 15), direction))?;
                let door = Door::random(self.random);
                sh(
                    K::Library {
                        tall: b.y_span() > 6,
                    },
                    door,
                    b,
                    direction,
                    depth,
                )
            }
            Factory::PortalRoom => {
                let b = self.free_box(foot, (-4, -1, 0), (11, 8, 16), direction)?;
                sh(K::PortalRoom, Door::Opening, b, direction, depth)
            }
        })
    }

    fn may_place(&self, weight: usize, depth: i32) -> bool {
        let (factory, _, max) = WEIGHTS[weight];
        let base = max == 0 || self.placed[weight] < max;
        base && match factory {
            Factory::Library => depth > 4,
            Factory::PortalRoom => depth > 5,
            _ => true,
        }
    }

    /// `generatePieceFromSmallDoor`.
    fn small_door_piece(
        &mut self,
        foot: [i32; 3],
        direction: Direction,
        depth: i32,
    ) -> Option<Piece> {
        // `updatePieceWeight`.
        let mut any = false;
        self.total_weight = 0;
        for &w in &self.current {
            let (_, weight, max) = WEIGHTS[w];
            if max > 0 && self.placed[w] < max {
                any = true;
            }
            self.total_weight += weight;
        }
        if !any {
            return None;
        }
        if let Some(factory) = self.imposed.take() {
            if let Some(piece) = self.create(factory, foot, direction, depth) {
                return Some(piece);
            }
        }
        for _ in 0..5 {
            let mut selection = self.random.next_int_bounded(self.total_weight);
            let mut i = 0;
            while i < self.current.len() {
                let w = self.current[i];
                selection -= WEIGHTS[w].1;
                if selection < 0 {
                    if !self.may_place(w, depth) || Some(w) == self.previous {
                        break;
                    }
                    if let Some(piece) = self.create(WEIGHTS[w].0, foot, direction, depth) {
                        self.placed[w] += 1;
                        self.previous = Some(w);
                        let max = WEIGHTS[w].2;
                        if !(max == 0 || self.placed[w] < max) {
                            self.current.remove(i);
                        }
                        return Some(piece);
                    }
                }
                i += 1;
            }
        }
        // `FillerCorridor.findPieceBox`.
        let probe =
            BoundingBox::orient((foot[0], foot[1], foot[2]), (-1, -1, 0), 5, 5, 4, direction);
        let other = self.pieces.iter().find(|p| p.bbox.intersects(&probe))?.bbox;
        if other.min_y != probe.min_y {
            return None;
        }
        for length in (1..=2).rev() {
            let b = BoundingBox::orient(
                (foot[0], foot[1], foot[2]),
                (-1, -1, 0),
                5,
                5,
                length,
                direction,
            );
            if !other.intersects(&b) {
                let b = BoundingBox::orient(
                    (foot[0], foot[1], foot[2]),
                    (-1, -1, 0),
                    5,
                    5,
                    length + 1,
                    direction,
                );
                if b.min_y <= 1 {
                    return None;
                }
                let steps = if direction.is_z() {
                    b.z_span()
                } else {
                    b.x_span()
                };
                return Some(sh(
                    StrongholdKind::FillerCorridor { steps },
                    Door::Opening,
                    b,
                    direction,
                    depth,
                ));
            }
        }
        None
    }

    /// `generateAndAddPiece`.
    fn add(&mut self, foot: [i32; 3], direction: Direction, depth: i32) {
        if depth > 50 {
            return;
        }
        if (foot[0] - self.start_min.0).abs() > 112 || (foot[2] - self.start_min.1).abs() > 112 {
            return;
        }
        if let Some(piece) = self.small_door_piece(foot, direction, depth + 1) {
            self.pieces.push(piece);
            self.pending.push(self.pieces.len() - 1);
        }
    }

    fn forward(&mut self, index: usize, x_off: i32, y_off: i32) {
        let p = &self.pieces[index];
        let (b, depth) = (p.bbox, p.gen_depth);
        let Some(o) = p.orientation else { return };
        let foot = match o {
            Direction::North => [b.min_x + x_off, b.min_y + y_off, b.min_z - 1],
            Direction::South => [b.min_x + x_off, b.min_y + y_off, b.max_z + 1],
            Direction::West => [b.min_x - 1, b.min_y + y_off, b.min_z + x_off],
            Direction::East => [b.max_x + 1, b.min_y + y_off, b.min_z + x_off],
        };
        self.add(foot, o, depth);
    }

    fn left(&mut self, index: usize, y_off: i32, z_off: i32) {
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
        self.add(foot, direction, depth);
    }

    fn right(&mut self, index: usize, y_off: i32, z_off: i32) {
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
        self.add(foot, direction, depth);
    }

    fn add_children(&mut self, index: usize) {
        let PieceKind::Stronghold(p) = &self.pieces[index].kind else {
            return;
        };
        let orientation = self.pieces[index].orientation;
        match p.kind.clone() {
            StrongholdKind::Start => {
                self.imposed = Some(Factory::FiveCrossing);
                self.forward(index, 1, 1);
            }
            StrongholdKind::StairsDown
            | StrongholdKind::ChestCorridor
            | StrongholdKind::PrisonHall
            | StrongholdKind::StraightStairsDown => self.forward(index, 1, 1),
            StrongholdKind::Straight { left, right } => {
                self.forward(index, 1, 1);
                if left {
                    self.left(index, 1, 2);
                }
                if right {
                    self.right(index, 1, 2);
                }
            }
            StrongholdKind::LeftTurn => {
                if !matches!(orientation, Some(Direction::North | Direction::East)) {
                    self.right(index, 1, 1);
                } else {
                    self.left(index, 1, 1);
                }
            }
            StrongholdKind::RightTurn => {
                if !matches!(orientation, Some(Direction::North | Direction::East)) {
                    self.left(index, 1, 1);
                } else {
                    self.right(index, 1, 1);
                }
            }
            StrongholdKind::RoomCrossing { .. } => {
                self.forward(index, 4, 1);
                self.left(index, 1, 4);
                self.right(index, 1, 4);
            }
            StrongholdKind::FiveCrossing {
                left_low,
                left_high,
                right_low,
                right_high,
            } => {
                let (mut a, mut b) = (3, 5);
                if matches!(orientation, Some(Direction::West | Direction::North)) {
                    a = 8 - a;
                    b = 8 - b;
                }
                self.forward(index, 5, 1);
                if left_low {
                    self.left(index, a, 1);
                }
                if left_high {
                    self.left(index, b, 7);
                }
                if right_low {
                    self.right(index, a, 1);
                }
                if right_high {
                    self.right(index, b, 7);
                }
            }
            StrongholdKind::PortalRoom => self.portal_room = true,
            StrongholdKind::Library { .. } | StrongholdKind::FillerCorridor { .. } => {}
        }
    }
}

/// `StrongholdStructure.generatePieces`, after the biome check at the
/// chunk's corner.
pub fn generate(gc: &mut GenContext) -> Result<Option<Vec<Piece>>, String> {
    if !gc.is_valid_biome((gc.min_block_x(), 0, gc.min_block_z())) {
        return Ok(None);
    }
    let (min_x, min_z) = (gc.min_block_x(), gc.min_block_z());
    let sea_level = gc.sea_level();
    let min_y = gc.env.heights.min_y;
    let seed = gc.env.seed;
    let mut tries: i64 = 0;
    loop {
        set_large_feature_seed(
            &mut gc.random,
            seed.wrapping_add(tries),
            gc.chunk.0,
            gc.chunk.1,
        );
        tries += 1;
        let direction = Direction::random(&mut gc.random);
        let start = Piece {
            kind: PieceKind::Stronghold(StrongholdPiece {
                kind: StrongholdKind::Start,
                entry_door: Door::Opening,
            }),
            bbox: make_bounding_box(min_x + 2, 64, min_z + 2, direction, 5, 11, 5),
            orientation: Some(direction),
            gen_depth: 0,
        };
        let start_min = (start.bbox.min_x, start.bbox.min_z);
        let mut layout = Layout {
            random: &mut gc.random,
            pieces: vec![start],
            current: (0..WEIGHTS.len()).collect(),
            placed: [0; 11],
            total_weight: 0,
            imposed: None,
            previous: None,
            portal_room: false,
            pending: Vec::new(),
            start_min,
        };
        layout.add_children(0);
        while !layout.pending.is_empty() {
            let pos = layout.random.next_int_bounded(layout.pending.len() as i32) as usize;
            let index = layout.pending.remove(pos);
            layout.add_children(index);
        }
        let portal_room = layout.portal_room;
        let mut pieces = layout.pieces;
        // `moveBelowSeaLevel`.
        let bb = encapsulating(pieces.iter().map(|p| &p.bbox)).expect("a start");
        let max_y = sea_level - 10;
        let mut y1 = bb.y_span() + min_y + 1;
        if y1 < max_y {
            y1 += gc.random.next_int_bounded(max_y - y1);
        }
        let dy = y1 - bb.max_y;
        for p in &mut pieces {
            p.moved_by(0, dy, 0);
        }
        if !pieces.is_empty() && portal_room {
            return Ok(Some(pieces));
        }
    }
}
