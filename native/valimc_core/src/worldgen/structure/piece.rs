//! Structure pieces as structure starts hold them: bounding boxes,
//! orientations, generation depths and each piece type's own fields, saved as
//! vanilla's `StructurePiece.createTag` writes them.

use super::super::random::Random;
use super::super::template::{Mirror, Rotation};

/// Vanilla's `BoundingBox` (inclusive on both ends).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct BoundingBox {
    pub min_x: i32,
    pub min_y: i32,
    pub min_z: i32,
    pub max_x: i32,
    pub max_y: i32,
    pub max_z: i32,
}

impl BoundingBox {
    /// The constructor, which swaps inverted bounds as vanilla's does.
    pub fn new(x0: i32, y0: i32, z0: i32, x1: i32, y1: i32, z1: i32) -> BoundingBox {
        BoundingBox {
            min_x: x0.min(x1),
            min_y: y0.min(y1),
            min_z: z0.min(z1),
            max_x: x0.max(x1),
            max_y: y0.max(y1),
            max_z: z0.max(z1),
        }
    }

    pub fn at(x: i32, y: i32, z: i32) -> BoundingBox {
        BoundingBox::new(x, y, z, x, y, z)
    }

    /// `BoundingBox.orientBox`: a box of `width` × `height` × `depth` from a
    /// foot position, offset, facing `direction`.
    #[allow(clippy::too_many_arguments)]
    pub fn orient(
        (fx, fy, fz): (i32, i32, i32),
        (ox, oy, oz): (i32, i32, i32),
        width: i32,
        height: i32,
        depth: i32,
        direction: Direction,
    ) -> BoundingBox {
        match direction {
            Direction::North => BoundingBox::new(
                fx + ox,
                fy + oy,
                fz - depth + 1 + oz,
                fx + width - 1 + ox,
                fy + height - 1 + oy,
                fz + oz,
            ),
            Direction::West => BoundingBox::new(
                fx - depth + 1 + oz,
                fy + oy,
                fz + ox,
                fx + oz,
                fy + height - 1 + oy,
                fz + width - 1 + ox,
            ),
            Direction::East => BoundingBox::new(
                fx + oz,
                fy + oy,
                fz + ox,
                fx + depth - 1 + oz,
                fy + height - 1 + oy,
                fz + width - 1 + ox,
            ),
            Direction::South => BoundingBox::new(
                fx + ox,
                fy + oy,
                fz + oz,
                fx + width - 1 + ox,
                fy + height - 1 + oy,
                fz + depth - 1 + oz,
            ),
        }
    }

    pub fn intersects(&self, o: &BoundingBox) -> bool {
        self.max_x >= o.min_x
            && self.min_x <= o.max_x
            && self.max_z >= o.min_z
            && self.min_z <= o.max_z
            && self.max_y >= o.min_y
            && self.min_y <= o.max_y
    }

    pub fn intersects_xz(&self, min_x: i32, min_z: i32, max_x: i32, max_z: i32) -> bool {
        self.max_x >= min_x && self.min_x <= max_x && self.max_z >= min_z && self.min_z <= max_z
    }

    pub fn is_inside(&self, x: i32, y: i32, z: i32) -> bool {
        x >= self.min_x
            && x <= self.max_x
            && z >= self.min_z
            && z <= self.max_z
            && y >= self.min_y
            && y <= self.max_y
    }

    pub fn encapsulate(&mut self, o: &BoundingBox) {
        self.min_x = self.min_x.min(o.min_x);
        self.min_y = self.min_y.min(o.min_y);
        self.min_z = self.min_z.min(o.min_z);
        self.max_x = self.max_x.max(o.max_x);
        self.max_y = self.max_y.max(o.max_y);
        self.max_z = self.max_z.max(o.max_z);
    }

    pub fn moved(&self, dx: i32, dy: i32, dz: i32) -> BoundingBox {
        BoundingBox {
            min_x: self.min_x + dx,
            min_y: self.min_y + dy,
            min_z: self.min_z + dz,
            max_x: self.max_x + dx,
            max_y: self.max_y + dy,
            max_z: self.max_z + dz,
        }
    }

    pub fn inflated(&self, x: i32, y: i32, z: i32) -> BoundingBox {
        BoundingBox::new(
            self.min_x - x,
            self.min_y - y,
            self.min_z - z,
            self.max_x + x,
            self.max_y + y,
            self.max_z + z,
        )
    }

    pub fn x_span(&self) -> i32 {
        self.max_x - self.min_x + 1
    }

    pub fn y_span(&self) -> i32 {
        self.max_y - self.min_y + 1
    }

    pub fn z_span(&self) -> i32 {
        self.max_z - self.min_z + 1
    }

    pub fn center(&self) -> (i32, i32, i32) {
        (
            self.min_x + (self.max_x - self.min_x + 1) / 2,
            self.min_y + (self.max_y - self.min_y + 1) / 2,
            self.min_z + (self.max_z - self.min_z + 1) / 2,
        )
    }

    pub fn nbt(&self) -> Nbt {
        Nbt::IntArray(vec![
            self.min_x, self.min_y, self.min_z, self.max_x, self.max_y, self.max_z,
        ])
    }
}

/// The box enclosing `boxes` (`BoundingBox.encapsulatingBoxes`).
pub fn encapsulating<'a>(mut boxes: impl Iterator<Item = &'a BoundingBox>) -> Option<BoundingBox> {
    let mut result = *boxes.next()?;
    for b in boxes {
        result.encapsulate(b);
    }
    Some(result)
}

/// A horizontal direction.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Direction {
    North,
    South,
    West,
    East,
}

impl Direction {
    /// `Direction.Plane.HORIZONTAL` in its order.
    pub const HORIZONTAL: [Direction; 4] = [
        Direction::North,
        Direction::East,
        Direction::South,
        Direction::West,
    ];

    /// `get2DDataValue`.
    pub fn data_2d(self) -> i32 {
        match self {
            Direction::South => 0,
            Direction::West => 1,
            Direction::North => 2,
            Direction::East => 3,
        }
    }

    /// `Plane.HORIZONTAL.getRandomDirection`.
    pub fn random(random: &mut Random) -> Direction {
        Direction::HORIZONTAL[random.next_int_bounded(4) as usize]
    }

    pub fn is_z(self) -> bool {
        matches!(self, Direction::North | Direction::South)
    }

    pub fn opposite(self) -> Direction {
        match self {
            Direction::North => Direction::South,
            Direction::South => Direction::North,
            Direction::West => Direction::East,
            Direction::East => Direction::West,
        }
    }

    pub fn clockwise(self) -> Direction {
        match self {
            Direction::North => Direction::East,
            Direction::East => Direction::South,
            Direction::South => Direction::West,
            Direction::West => Direction::North,
        }
    }

    /// The (x, z) step of a block in this direction.
    pub fn step(self) -> (i32, i32) {
        match self {
            Direction::North => (0, -1),
            Direction::South => (0, 1),
            Direction::West => (-1, 0),
            Direction::East => (1, 0),
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Direction::North => "north",
            Direction::South => "south",
            Direction::West => "west",
            Direction::East => "east",
        }
    }

    pub fn parse(name: &str) -> Option<Direction> {
        Some(match name {
            "north" => Direction::North,
            "south" => Direction::South,
            "west" => Direction::West,
            "east" => Direction::East,
            _ => return None,
        })
    }

    pub fn counter_clockwise(self) -> Direction {
        match self {
            Direction::North => Direction::West,
            Direction::West => Direction::South,
            Direction::South => Direction::East,
            Direction::East => Direction::North,
        }
    }
}

/// An NBT value, printed canonically for parity checks (compound keys
/// sorted; see `StructureOracle`).
#[derive(Clone, Debug, PartialEq)]
pub enum Nbt {
    Byte(i8),
    Short(i16),
    Int(i32),
    Long(i64),
    Float(f32),
    String(String),
    /// Canonical SNBT from the facts (a pool element as vanilla saves it).
    Raw(String),
    List(Vec<Nbt>),
    Compound(Vec<(String, Nbt)>),
    IntArray(Vec<i32>),
}

impl Nbt {
    pub fn bool(value: bool) -> Nbt {
        Nbt::Byte(value as i8)
    }

    pub fn string(value: &str) -> Nbt {
        Nbt::String(value.to_string())
    }

    pub fn snbt(&self) -> String {
        let mut out = String::new();
        self.write(&mut out);
        out
    }

    fn write(&self, out: &mut String) {
        use std::fmt::Write;
        match self {
            Nbt::Byte(v) => {
                let _ = write!(out, "{v}b");
            }
            Nbt::Short(v) => {
                let _ = write!(out, "{v}s");
            }
            Nbt::Int(v) => {
                let _ = write!(out, "{v}");
            }
            Nbt::Long(v) => {
                let _ = write!(out, "{v}L");
            }
            Nbt::Float(v) => {
                out.push_str(&java_float(*v));
                out.push('f');
            }
            Nbt::String(s) => quote(s, out),
            Nbt::Raw(s) => out.push_str(s),
            Nbt::List(items) => {
                out.push('[');
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    item.write(out);
                }
                out.push(']');
            }
            Nbt::Compound(fields) => {
                let mut sorted: Vec<&(String, Nbt)> = fields.iter().collect();
                sorted.sort_by(|a, b| a.0.cmp(&b.0));
                out.push('{');
                for (i, (key, value)) in sorted.into_iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    out.push_str(key);
                    out.push(':');
                    value.write(out);
                }
                out.push('}');
            }
            Nbt::IntArray(values) => {
                out.push_str("[I;");
                for (i, v) in values.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    let _ = write!(out, "{v}");
                }
                out.push(']');
            }
        }
    }
}

/// `Float.toString`: the shortest decimal that reads back as the float, in
/// plain notation from 10^-3 to 10^7 (always with a fraction digit) and in
/// computerized scientific notation otherwise.
pub fn java_float(v: f32) -> String {
    if v.is_nan() {
        return "NaN".into();
    }
    if v.is_infinite() {
        return if v > 0.0 { "Infinity" } else { "-Infinity" }.into();
    }
    if v == 0.0 {
        return if v.is_sign_negative() { "-0.0" } else { "0.0" }.into();
    }
    let magnitude = v.abs();
    if (1e-3..1e7).contains(&magnitude) {
        let plain = format!("{v}");
        return if plain.contains('.') {
            plain
        } else {
            plain + ".0"
        };
    }
    // Rust's `{:e}` gives the same shortest digits: "1.5e-4" or "1e7".
    let scientific = format!("{v:e}");
    let (mantissa, exponent) = scientific.split_once('e').expect("exponent");
    let mantissa = if mantissa.contains('.') {
        mantissa.to_string()
    } else {
        format!("{mantissa}.0")
    };
    format!("{mantissa}E{exponent}")
}

/// A string as Gson quotes it (HTML-safe escapes included).
fn quote(s: &str, out: &mut String) {
    use std::fmt::Write;
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '<' | '>' | '&' | '=' | '\'' => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

/// A structure piece: its type with its own fields, bounding box,
/// orientation and generation depth.
#[derive(Clone, Debug, PartialEq)]
pub struct Piece {
    pub kind: PieceKind,
    pub bbox: BoundingBox,
    pub orientation: Option<Direction>,
    pub gen_depth: i32,
}

impl Piece {
    /// What placement changes in a piece and vanilla saves with its start
    /// (VMC-077n): its box, and a temple's ground height and what it placed
    /// once, a template's position (a shipwreck's height adjustment), a spider
    /// corridor's spawner, a fortress corridor's chest or throne's spawner, a
    /// stronghold room's chest or spawner.
    pub fn placement_state(&self) -> Vec<i32> {
        let b = &self.bbox;
        let mut out = vec![b.min_x, b.min_y, b.min_z, b.max_x, b.max_y, b.max_z];
        match &self.kind {
            PieceKind::Scattered {
                height_position,
                placed,
                ..
            } => {
                out.push(*height_position);
                out.extend(placed.map(i32::from));
            }
            PieceKind::Template(t) => {
                out.extend(t.position);
                if let TemplateKind::Shipwreck {
                    height_adjusted, ..
                } = t.kind
                {
                    out.push(height_adjusted.into());
                }
            }
            PieceKind::Mineshaft(super::mineshaft::MineshaftPiece::Corridor {
                placed_spider,
                ..
            }) => out.push((*placed_spider).into()),
            PieceKind::Fortress(
                super::fortress::FortressPiece::SmallCorridorLeftTurn { chest }
                | super::fortress::FortressPiece::SmallCorridorRightTurn { chest },
            ) => out.push((*chest).into()),
            PieceKind::Fortress(super::fortress::FortressPiece::MonsterThrone { spawner }) => {
                out.push((*spawner).into())
            }
            PieceKind::Stronghold(s) => out.push(s.placed.into()),
            _ => {}
        }
        out
    }

    /// Put back a `placement_state`.
    pub fn restore_placement_state(&mut self, state: &[i32]) -> Result<(), String> {
        let bad = || "a piece's placement state does not fit it".to_string();
        let (bbox, rest) = state.split_at_checked(6).ok_or_else(bad)?;
        self.bbox = BoundingBox {
            min_x: bbox[0],
            min_y: bbox[1],
            min_z: bbox[2],
            max_x: bbox[3],
            max_y: bbox[4],
            max_z: bbox[5],
        };
        let flag = |v: i32| v != 0;
        match (&mut self.kind, rest) {
            (
                PieceKind::Scattered {
                    height_position,
                    placed,
                    ..
                },
                [h, a, b, c, d],
            ) => {
                *height_position = *h;
                *placed = [flag(*a), flag(*b), flag(*c), flag(*d)];
            }
            (PieceKind::Template(t), [x, y, z, more @ ..]) => {
                t.position = [*x, *y, *z];
                match (&mut t.kind, more) {
                    (
                        TemplateKind::Shipwreck {
                            height_adjusted, ..
                        },
                        [adjusted],
                    ) => *height_adjusted = flag(*adjusted),
                    (TemplateKind::Shipwreck { .. }, _) => return Err(bad()),
                    (_, []) => {}
                    _ => return Err(bad()),
                }
            }
            (
                PieceKind::Mineshaft(super::mineshaft::MineshaftPiece::Corridor {
                    placed_spider,
                    ..
                }),
                [v],
            ) => *placed_spider = flag(*v),
            (
                PieceKind::Fortress(
                    super::fortress::FortressPiece::SmallCorridorLeftTurn { chest }
                    | super::fortress::FortressPiece::SmallCorridorRightTurn { chest },
                ),
                [v],
            ) => *chest = flag(*v),
            (
                PieceKind::Fortress(super::fortress::FortressPiece::MonsterThrone { spawner }),
                [v],
            ) => *spawner = flag(*v),
            (PieceKind::Stronghold(s), [v]) => s.placed = flag(*v),
            (
                PieceKind::Scattered { .. }
                | PieceKind::Template(_)
                | PieceKind::Mineshaft(super::mineshaft::MineshaftPiece::Corridor { .. })
                | PieceKind::Fortress(
                    super::fortress::FortressPiece::SmallCorridorLeftTurn { .. }
                    | super::fortress::FortressPiece::SmallCorridorRightTurn { .. }
                    | super::fortress::FortressPiece::MonsterThrone { .. },
                )
                | PieceKind::Stronghold(_),
                _,
            ) => return Err(bad()),
            (_, []) => {}
            _ => return Err(bad()),
        }
        Ok(())
    }
}

/// The piece types with their own saved fields.
#[derive(Clone, Debug, PartialEq)]
pub enum PieceKind {
    /// `ScatteredFeaturePiece`s: desert and jungle temples and swamp huts,
    /// with their size, ground height (-1 until placed) and what placement
    /// has done once (`placed`, in saved order: a desert pyramid's chests by
    /// direction, a jungle temple's main and hidden chests and its traps, a
    /// swamp hut's witch and cat).
    Scattered {
        kind: ScatteredKind,
        width: i32,
        height: i32,
        depth: i32,
        height_position: i32,
        placed: [bool; 4],
    },
    BuriedTreasure,
    /// `TemplateStructurePiece`s.
    Template(TemplatePiece),
    /// `PoolElementStructurePiece`s.
    Jigsaw(super::jigsaw::JigsawPiece),
    Mineshaft(super::mineshaft::MineshaftPiece),
    Stronghold(super::stronghold::StrongholdPiece),
    Fortress(super::fortress::FortressPiece),
    /// An ocean monument's building with its rooms (which are not saved).
    Monument(Box<super::monument::Building>),
}

/// A template piece: the template's saved name, its position and placement
/// (the pivot only shapes the box), and its type's fields.
#[derive(Clone, Debug, PartialEq)]
pub struct TemplatePiece {
    pub kind: TemplateKind,
    pub name: String,
    pub position: [i32; 3],
    pub rotation: Rotation,
    pub mirror: Mirror,
}

#[derive(Clone, Debug, PartialEq)]
pub enum TemplateKind {
    Igloo,
    Shipwreck {
        beached: bool,
        height_adjusted: bool,
    },
    OceanRuin {
        integrity: f32,
        warm: bool,
        large: bool,
    },
    RuinedPortal {
        vertical_placement: &'static str,
        cold: bool,
        mossiness: f32,
        air_pocket: bool,
        overgrown: bool,
        vines: bool,
        replace_with_blackstone: bool,
    },
    NetherFossil,
    EndCity {
        overwrite: bool,
    },
    /// A woodland mansion piece (template `woodland_mansion/NAME`).
    Mansion,
}

/// `Rotation.LEGACY_CODEC`: the enum constant's name.
pub fn rotation_name(rotation: Rotation) -> &'static str {
    match rotation {
        Rotation::None => "NONE",
        Rotation::Clockwise90 => "CLOCKWISE_90",
        Rotation::Clockwise180 => "CLOCKWISE_180",
        Rotation::Counterclockwise90 => "COUNTERCLOCKWISE_90",
    }
}

pub fn mirror_name(mirror: Mirror) -> &'static str {
    match mirror {
        Mirror::None => "NONE",
        Mirror::LeftRight => "LEFT_RIGHT",
        Mirror::FrontBack => "FRONT_BACK",
    }
}

/// `Rotation.getRotated`.
pub fn rotated(base: Rotation, by: Rotation) -> Rotation {
    let index = |r: Rotation| match r {
        Rotation::None => 0,
        Rotation::Clockwise90 => 1,
        Rotation::Clockwise180 => 2,
        Rotation::Counterclockwise90 => 3,
    };
    super::super::template::ROTATIONS[(index(base) + index(by)) % 4]
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScatteredKind {
    DesertPyramid,
    JungleTemple,
    SwampHut,
}

impl Piece {
    /// The piece type's registry identifier.
    pub fn id(&self) -> &'static str {
        match &self.kind {
            PieceKind::Scattered { kind, .. } => match kind {
                ScatteredKind::DesertPyramid => "minecraft:tedp",
                ScatteredKind::JungleTemple => "minecraft:tejp",
                ScatteredKind::SwampHut => "minecraft:tesh",
            },
            PieceKind::BuriedTreasure => "minecraft:btp",
            PieceKind::Template(t) => match t.kind {
                TemplateKind::Igloo => "minecraft:iglu",
                TemplateKind::Shipwreck { .. } => "minecraft:shipwreck",
                TemplateKind::OceanRuin { .. } => "minecraft:orp",
                TemplateKind::RuinedPortal { .. } => "minecraft:rupo",
                TemplateKind::NetherFossil => "minecraft:nefos",
                TemplateKind::EndCity { .. } => "minecraft:ecp",
                TemplateKind::Mansion => "minecraft:wmp",
            },
            PieceKind::Jigsaw(_) => "minecraft:jigsaw",
            PieceKind::Mineshaft(m) => m.id(),
            PieceKind::Stronghold(s) => s.id(),
            PieceKind::Fortress(f) => f.id(),
            PieceKind::Monument(_) => "minecraft:omb",
        }
    }

    /// `StructurePiece.move`; template pieces move their template too.
    pub fn moved_by(&mut self, dx: i32, dy: i32, dz: i32) {
        self.bbox = self.bbox.moved(dx, dy, dz);
        match &mut self.kind {
            PieceKind::Template(t) => {
                t.position = [t.position[0] + dx, t.position[1] + dy, t.position[2] + dz];
            }
            PieceKind::Jigsaw(j) => {
                j.position = [j.position[0] + dx, j.position[1] + dy, j.position[2] + dz];
            }
            PieceKind::Mineshaft(super::mineshaft::MineshaftPiece::Room { entrances, .. }) => {
                for entrance in entrances {
                    *entrance = entrance.moved(dx, dy, dz);
                }
            }
            _ => {}
        }
    }

    /// `StructurePiece.createTag`.
    pub fn save(&self) -> Nbt {
        let mut fields = vec![
            ("id".to_string(), Nbt::string(self.id())),
            ("BB".to_string(), self.bbox.nbt()),
            (
                "O".to_string(),
                Nbt::Int(self.orientation.map_or(-1, Direction::data_2d)),
            ),
            ("GD".to_string(), Nbt::Int(self.gen_depth)),
        ];
        let mut put = |key: &str, value: Nbt| fields.push((key.to_string(), value));
        match &self.kind {
            PieceKind::Scattered {
                kind,
                width,
                height,
                depth,
                height_position,
                placed,
            } => {
                put("Width", Nbt::Int(*width));
                put("Height", Nbt::Int(*height));
                put("Depth", Nbt::Int(*depth));
                put("HPos", Nbt::Int(*height_position));
                let flags: &[&str] = match kind {
                    ScatteredKind::DesertPyramid => &[
                        "hasPlacedChest0",
                        "hasPlacedChest1",
                        "hasPlacedChest2",
                        "hasPlacedChest3",
                    ],
                    ScatteredKind::JungleTemple => &[
                        "placedMainChest",
                        "placedHiddenChest",
                        "placedTrap1",
                        "placedTrap2",
                    ],
                    ScatteredKind::SwampHut => &["Witch", "Cat"],
                };
                for (flag, done) in flags.iter().zip(placed) {
                    put(flag, Nbt::bool(*done));
                }
            }
            PieceKind::BuriedTreasure => {}
            PieceKind::Jigsaw(j) => j.save(&mut put),
            PieceKind::Mineshaft(m) => m.save(&mut put),
            PieceKind::Stronghold(s) => s.save(&mut put),
            PieceKind::Fortress(f) => f.save(&mut put),
            PieceKind::Monument(_) => {}
            PieceKind::Template(t) => {
                put("TPX", Nbt::Int(t.position[0]));
                put("TPY", Nbt::Int(t.position[1]));
                put("TPZ", Nbt::Int(t.position[2]));
                put("Template", Nbt::string(&t.name));
                let rot = Nbt::string(rotation_name(t.rotation));
                match &t.kind {
                    TemplateKind::Igloo | TemplateKind::NetherFossil => put("Rot", rot),
                    TemplateKind::Shipwreck {
                        beached,
                        height_adjusted,
                    } => {
                        put("isBeached", Nbt::bool(*beached));
                        put("Rot", rot);
                        put("height_adjusted", Nbt::bool(*height_adjusted));
                    }
                    TemplateKind::OceanRuin {
                        integrity,
                        warm,
                        large,
                    } => {
                        put("Rot", rot);
                        put("Integrity", Nbt::Float(*integrity));
                        put(
                            "BiomeType",
                            Nbt::string(if *warm { "WARM" } else { "COLD" }),
                        );
                        put("IsLarge", Nbt::bool(*large));
                    }
                    TemplateKind::RuinedPortal {
                        vertical_placement,
                        cold,
                        mossiness,
                        air_pocket,
                        overgrown,
                        vines,
                        replace_with_blackstone,
                    } => {
                        put("Rotation", rot);
                        put("Mirror", Nbt::string(mirror_name(t.mirror)));
                        put("VerticalPlacement", Nbt::string(vertical_placement));
                        put(
                            "Properties",
                            Nbt::Compound(vec![
                                ("cold".into(), Nbt::bool(*cold)),
                                ("mossiness".into(), Nbt::Float(*mossiness)),
                                ("air_pocket".into(), Nbt::bool(*air_pocket)),
                                ("overgrown".into(), Nbt::bool(*overgrown)),
                                ("vines".into(), Nbt::bool(*vines)),
                                (
                                    "replace_with_blackstone".into(),
                                    Nbt::bool(*replace_with_blackstone),
                                ),
                            ]),
                        );
                    }
                    TemplateKind::EndCity { overwrite } => {
                        put("Rot", rot);
                        put("OW", Nbt::bool(*overwrite));
                    }
                    TemplateKind::Mansion => {
                        put("Rot", rot);
                        put("Mi", Nbt::string(mirror_name(t.mirror)));
                    }
                }
            }
        }
        Nbt::Compound(fields)
    }
}

/// `StructurePiece.makeBoundingBox`: a box from its corner, `width` across
/// and `depth` along `direction`.
pub fn make_bounding_box(
    x: i32,
    y: i32,
    z: i32,
    direction: Direction,
    width: i32,
    height: i32,
    depth: i32,
) -> BoundingBox {
    if direction.is_z() {
        BoundingBox::new(x, y, z, x + width - 1, y + height - 1, z + depth - 1)
    } else {
        BoundingBox::new(x, y, z, x + depth - 1, y + height - 1, z + width - 1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn oriented_boxes_follow_their_direction() {
        let foot = (10, 64, 20);
        assert_eq!(
            BoundingBox::orient(foot, (-1, 0, 0), 5, 3, 7, Direction::North),
            BoundingBox::new(9, 64, 14, 13, 66, 20)
        );
        assert_eq!(
            BoundingBox::orient(foot, (-1, 0, 0), 5, 3, 7, Direction::East),
            BoundingBox::new(10, 64, 19, 16, 66, 23)
        );
        assert_eq!(
            make_bounding_box(0, 64, 0, Direction::West, 21, 15, 9),
            BoundingBox::new(0, 64, 0, 8, 78, 20)
        );
    }

    #[test]
    fn pieces_save_as_vanilla_prints_them() {
        let piece = Piece {
            kind: PieceKind::Scattered {
                kind: ScatteredKind::JungleTemple,
                width: 12,
                height: 10,
                depth: 15,
                height_position: -1,
                placed: [false; 4],
            },
            bbox: BoundingBox::new(-51344, 64, -317936, -51333, 73, -317922),
            orientation: Some(Direction::South),
            gen_depth: 0,
        };
        assert_eq!(
            piece.save().snbt(),
            "{BB:[I;-51344,64,-317936,-51333,73,-317922],Depth:15,GD:0,HPos:-1,Height:10,O:0,\
             Width:12,id:\"minecraft:tejp\",placedHiddenChest:0b,placedMainChest:0b,\
             placedTrap1:0b,placedTrap2:0b}"
        );
        assert_eq!(Nbt::string("a<b").snbt(), "\"a\\u003cb\"");
    }

    #[test]
    fn placement_state_restores_a_settled_temple() {
        let fresh = || Piece {
            kind: PieceKind::Scattered {
                kind: ScatteredKind::DesertPyramid,
                width: 21,
                height: 15,
                depth: 21,
                height_position: -1,
                placed: [false; 4],
            },
            bbox: BoundingBox::new(0, 64, 0, 20, 78, 20),
            orientation: Some(Direction::North),
            gen_depth: 0,
        };
        let mut settled = fresh();
        settled.bbox = BoundingBox::new(0, 58, 0, 20, 72, 20);
        if let PieceKind::Scattered {
            height_position,
            placed,
            ..
        } = &mut settled.kind
        {
            *height_position = 61;
            placed[2] = true;
        }
        let state = settled.placement_state();
        let mut restored = fresh();
        restored.restore_placement_state(&state).unwrap();
        assert_eq!(restored.save().snbt(), settled.save().snbt());
        assert!(fresh().restore_placement_state(&state[..6]).is_err());
    }
}
