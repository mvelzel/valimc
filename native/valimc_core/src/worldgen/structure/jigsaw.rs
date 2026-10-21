//! Jigsaw structures (VMC-025e3): template pools and their elements, pool
//! aliases and vanilla's `JigsawPlacement`: a start element from the start
//! pool, then breadth-first by placement priority, every jigsaw block of a
//! placed piece tries the shuffled elements of its pool (then the fallback
//! pool) in shuffled rotations until one fits into the free space of its
//! context: the structure's range around the start, or the inside of a rigid
//! parent the child attaches within.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::{Arc, OnceLock};

use super::super::blocks::Heightmap;
use super::super::json::Json;
use super::super::providers::{GenContext as HeightContext, HeightProvider, Weighted};
use super::super::random::Random;
use super::super::template::{transform, Mirror, Rotation, ROTATIONS};
use super::piece::{rotation_name, BoundingBox, Nbt, Piece, PieceKind};
use super::templated::template_box;
use super::{GenContext, StructureRegistry};

/// `StructureTemplatePool.Projection`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Projection {
    TerrainMatching,
    Rigid,
}

impl Projection {
    fn parse(json: &Json) -> Result<Projection, String> {
        match json.as_str()? {
            "rigid" => Ok(Projection::Rigid),
            "terrain_matching" => Ok(Projection::TerrainMatching),
            other => Err(format!("unknown projection {other}")),
        }
    }

    fn name(self) -> &'static str {
        match self {
            Projection::Rigid => "rigid",
            Projection::TerrainMatching => "terrain_matching",
        }
    }
}

/// A pool element (`StructurePoolElement`), with the NBT a piece saves it
/// as.
#[derive(Debug)]
pub enum Element {
    /// Single and legacy single elements: one template.
    Single {
        location: String,
        projection: Projection,
        nbt: String,
    },
    List {
        elements: Vec<Element>,
        projection: Projection,
        nbt: String,
    },
    Feature {
        projection: Projection,
        nbt: String,
    },
    Empty,
}

impl Element {
    fn parse(json: &Json, nbt: String) -> Result<Element, String> {
        let projection = || Projection::parse(json.field("projection")?);
        Ok(match json.field("element_type")?.as_str()? {
            "minecraft:single_pool_element" | "minecraft:legacy_single_pool_element" => {
                Element::Single {
                    location: json.field("location")?.as_str()?.to_string(),
                    projection: projection()?,
                    nbt,
                }
            }
            "minecraft:list_pool_element" => {
                // The list's projection is set on each of its elements.
                let projection = projection()?;
                let elements = json
                    .field("elements")?
                    .as_array()?
                    .iter()
                    .map(|e| {
                        Ok(match Element::parse(e, String::new())? {
                            Element::Single { location, .. } => Element::Single {
                                location,
                                projection,
                                nbt: String::new(),
                            },
                            Element::Feature { .. } => Element::Feature {
                                projection,
                                nbt: String::new(),
                            },
                            other => other,
                        })
                    })
                    .collect::<Result<Vec<_>, String>>()?;
                if elements.is_empty() {
                    return Err("a list element needs elements".into());
                }
                Element::List {
                    elements,
                    projection,
                    nbt,
                }
            }
            "minecraft:feature_pool_element" => Element::Feature {
                projection: projection()?,
                nbt,
            },
            "minecraft:empty_pool_element" => Element::Empty,
            other => return Err(format!("unknown pool element {other}")),
        })
    }

    fn projection(&self) -> Projection {
        match self {
            Element::Single { projection, .. }
            | Element::List { projection, .. }
            | Element::Feature { projection, .. } => *projection,
            Element::Empty => Projection::TerrainMatching,
        }
    }

    fn nbt(&self) -> &str {
        match self {
            Element::Single { nbt, .. }
            | Element::List { nbt, .. }
            | Element::Feature { nbt, .. } => nbt,
            Element::Empty => "{element_type:\"minecraft:empty_pool_element\"}",
        }
    }

    /// `getBoundingBox`.
    fn bounding_box(
        &self,
        registry: &StructureRegistry,
        position: [i32; 3],
        rotation: Rotation,
    ) -> Result<BoundingBox, String> {
        match self {
            Element::Single { location, .. } => Ok(template_box(
                registry.template(location)?.size,
                position,
                rotation,
                [0, 0, 0],
                Mirror::None,
            )),
            Element::List { elements, .. } => {
                let mut result: Option<BoundingBox> = None;
                for element in elements {
                    if matches!(element, Element::Empty) {
                        continue;
                    }
                    let b = element.bounding_box(registry, position, rotation)?;
                    match &mut result {
                        None => result = Some(b),
                        Some(r) => r.encapsulate(&b),
                    }
                }
                result.ok_or_else(|| "a list element without boxes".into())
            }
            Element::Feature { .. } => Ok(BoundingBox::new(
                position[0],
                position[1],
                position[2],
                position[0],
                position[1],
                position[2],
            )),
            Element::Empty => Err("the empty element has no box".into()),
        }
    }

    /// `getShuffledJigsawBlocks`: the template's jigsaw blocks (the palette
    /// chosen by position) rotated and placed at `position`, shuffled, then
    /// by selection priority, highest first.
    fn shuffled_jigsaws(
        &self,
        registry: &StructureRegistry,
        position: [i32; 3],
        rotation: Rotation,
        random: &mut Random,
    ) -> Result<Vec<Jigsaw>, String> {
        match self {
            Element::Single { location, .. } => {
                let outline = registry.template(location)?;
                if outline.palettes == 0 {
                    return Ok(Vec::new());
                }
                let palette = if outline.palettes == 1 {
                    0
                } else {
                    let [x, y, z] = position;
                    Random::legacy(position_seed(x, y, z)).next_int_bounded(outline.palettes as i32)
                        as usize
                };
                let mut jigsaws: Vec<Jigsaw> = match outline.jigsaws.get(palette) {
                    None => Vec::new(),
                    Some(list) => list
                        .iter()
                        .map(|info| {
                            let p = transform(info.pos, Mirror::None, rotation, [0, 0, 0]);
                            let (front, top) = parse_orientation(&info.orientation)?;
                            Ok(Jigsaw {
                                pos: [p[0] + position[0], p[1] + position[1], p[2] + position[2]],
                                front: front.rotated(rotation),
                                top: top.rotated(rotation),
                                rollable: info.rollable,
                                name: Some(info.name.clone()),
                                pool: info.pool.clone(),
                                target: info.target.clone(),
                                placement_priority: info.placement_priority,
                                selection_priority: info.selection_priority,
                            })
                        })
                        .collect::<Result<_, String>>()?,
                };
                shuffle(&mut jigsaws, random);
                jigsaws.sort_by_key(|j| std::cmp::Reverse(j.selection_priority));
                Ok(jigsaws)
            }
            Element::List { elements, .. } => {
                elements[0].shuffled_jigsaws(registry, position, rotation, random)
            }
            Element::Feature { .. } => Ok(vec![Jigsaw {
                pos: position,
                front: Dir::Down,
                top: Dir::South,
                rollable: true,
                name: None,
                pool: EMPTY_POOL.to_string(),
                target: "minecraft:empty".to_string(),
                placement_priority: 0,
                selection_priority: 0,
            }]),
            Element::Empty => Ok(Vec::new()),
        }
    }
}

const EMPTY_POOL: &str = "minecraft:empty";

/// `Mth.getSeed`.
fn position_seed(x: i32, y: i32, z: i32) -> i64 {
    let seed = (x.wrapping_mul(3_129_871) as i64) ^ (z as i64).wrapping_mul(116_129_781) ^ y as i64;
    let seed = seed
        .wrapping_mul(seed)
        .wrapping_mul(42_317_861)
        .wrapping_add(seed.wrapping_mul(11));
    seed >> 16
}

/// `Util.shuffle`.
fn shuffle<T>(list: &mut [T], random: &mut Random) {
    for i in (2..=list.len()).rev() {
        let swap_to = random.next_int_bounded(i as i32) as usize;
        list.swap(i - 1, swap_to);
    }
}

/// The six directions.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Dir {
    Down,
    Up,
    North,
    South,
    West,
    East,
}

impl Dir {
    fn parse(name: &str) -> Result<Dir, String> {
        Ok(match name {
            "down" => Dir::Down,
            "up" => Dir::Up,
            "north" => Dir::North,
            "south" => Dir::South,
            "west" => Dir::West,
            "east" => Dir::East,
            other => return Err(format!("unknown direction {other}")),
        })
    }

    fn step(self) -> [i32; 3] {
        match self {
            Dir::Down => [0, -1, 0],
            Dir::Up => [0, 1, 0],
            Dir::North => [0, 0, -1],
            Dir::South => [0, 0, 1],
            Dir::West => [-1, 0, 0],
            Dir::East => [1, 0, 0],
        }
    }

    fn opposite(self) -> Dir {
        match self {
            Dir::Down => Dir::Up,
            Dir::Up => Dir::Down,
            Dir::North => Dir::South,
            Dir::South => Dir::North,
            Dir::West => Dir::East,
            Dir::East => Dir::West,
        }
    }

    fn clockwise(self) -> Dir {
        match self {
            Dir::North => Dir::East,
            Dir::East => Dir::South,
            Dir::South => Dir::West,
            Dir::West => Dir::North,
            vertical => vertical,
        }
    }

    /// A rotation about the Y axis.
    fn rotated(self, rotation: Rotation) -> Dir {
        match rotation {
            Rotation::None => self,
            Rotation::Clockwise90 => self.clockwise(),
            Rotation::Clockwise180 => self.clockwise().clockwise(),
            Rotation::Counterclockwise90 => self.clockwise().clockwise().clockwise(),
        }
    }
}

/// A jigsaw block's `FrontAndTop` orientation, as `front_top`.
fn parse_orientation(name: &str) -> Result<(Dir, Dir), String> {
    let (front, top) = name
        .split_once('_')
        .ok_or_else(|| format!("bad jigsaw orientation {name}"))?;
    Ok((Dir::parse(front)?, Dir::parse(top)?))
}

/// A jigsaw block placed with its element.
#[derive(Clone, Debug)]
struct Jigsaw {
    pos: [i32; 3],
    front: Dir,
    top: Dir,
    rollable: bool,
    name: Option<String>,
    pool: String,
    target: String,
    placement_priority: i32,
    selection_priority: i32,
}

/// `JigsawBlock.canAttach`.
fn can_attach(source: &Jigsaw, target: &Jigsaw) -> bool {
    source.front == target.front.opposite()
        && (source.rollable || source.top == target.top)
        && target
            .name
            .as_ref()
            .is_none_or(|name| *name == source.target)
}

/// A template pool: its fallback and its elements, each repeated by weight.
#[derive(Debug)]
pub struct Pool {
    pub fallback: String,
    pub templates: Vec<Arc<Element>>,
    max_size: OnceLock<i32>,
}

impl Pool {
    pub fn parse(json: &Json) -> Result<Pool, String> {
        let mut templates = Vec::new();
        for entry in json.field("elements")?.as_array()? {
            let element = Arc::new(Element::parse(
                entry.field("element")?,
                entry.field("nbt")?.as_str()?.to_string(),
            )?);
            for _ in 0..entry.field("weight")?.as_i32()? {
                templates.push(element.clone());
            }
        }
        Ok(Pool {
            fallback: json.field("fallback")?.as_str()?.to_string(),
            templates,
            max_size: OnceLock::new(),
        })
    }

    /// `getMaxSize`: the tallest element's height.
    fn max_size(&self, registry: &StructureRegistry) -> Result<i32, String> {
        if let Some(&size) = self.max_size.get() {
            return Ok(size);
        }
        let mut size = 0;
        for element in &self.templates {
            if !matches!(**element, Element::Empty) {
                size = size.max(
                    element
                        .bounding_box(registry, [0, 0, 0], Rotation::None)?
                        .y_span(),
                );
            }
        }
        Ok(*self.max_size.get_or_init(|| size))
    }

    fn shuffled(&self, random: &mut Random) -> Vec<Arc<Element>> {
        let mut copy = self.templates.clone();
        shuffle(&mut copy, random);
        copy
    }
}

/// A pool alias binding (`PoolAliasBinding`).
#[derive(Clone, Debug)]
pub enum AliasBinding {
    Direct(String, String),
    Random(String, Weighted<String>),
    RandomGroup(Weighted<Vec<AliasBinding>>),
}

impl AliasBinding {
    pub fn parse(json: &Json) -> Result<AliasBinding, String> {
        Ok(match json.field("type")?.as_str()? {
            "minecraft:direct" => AliasBinding::Direct(
                json.field("alias")?.as_str()?.to_string(),
                json.field("target")?.as_str()?.to_string(),
            ),
            "minecraft:random" => AliasBinding::Random(
                json.field("alias")?.as_str()?.to_string(),
                Weighted::parse(json.field("targets")?, |t| Ok(t.as_str()?.to_string()))?,
            ),
            "minecraft:random_group" => {
                AliasBinding::RandomGroup(Weighted::parse(json.field("groups")?, |group| {
                    group.as_array()?.iter().map(AliasBinding::parse).collect()
                })?)
            }
            other => return Err(format!("unknown pool alias binding {other}")),
        })
    }

    fn resolve(&self, random: &mut Random, out: &mut HashMap<String, String>) {
        match self {
            AliasBinding::Direct(alias, target) => {
                out.insert(alias.clone(), target.clone());
            }
            AliasBinding::Random(alias, targets) => {
                out.insert(alias.clone(), targets.pick(random).clone());
            }
            AliasBinding::RandomGroup(groups) => {
                for binding in groups.pick(random).clone() {
                    binding.resolve(random, out);
                }
            }
        }
    }
}

/// `PoolAliasLookup.create`: bindings resolved by a positional random of
/// the level seed at the start position.
fn alias_lookup(
    bindings: &[AliasBinding],
    position: [i32; 3],
    seed: i64,
) -> HashMap<String, String> {
    let mut out = HashMap::new();
    if bindings.is_empty() {
        return out;
    }
    let mut random =
        Random::legacy(seed)
            .fork_positional()
            .at(position[0], position[1], position[2]);
    for binding in bindings {
        binding.resolve(&mut random, &mut out);
    }
    out
}

/// A jigsaw structure's configuration (`JigsawStructure`).
#[derive(Clone, Debug)]
pub struct JigsawConfig {
    pub start_pool: String,
    pub start_jigsaw_name: Option<String>,
    pub max_depth: i32,
    pub start_height: HeightProvider,
    pub use_expansion_hack: bool,
    pub project_start_to_heightmap: Option<Heightmap>,
    pub max_distance_horizontal: i32,
    pub max_distance_vertical: i32,
    pub pool_aliases: Vec<AliasBinding>,
    pub padding_bottom: i32,
    pub padding_top: i32,
    pub ignore_waterlogging: bool,
}

impl JigsawConfig {
    pub fn parse(json: &Json) -> Result<JigsawConfig, String> {
        let (horizontal, vertical) = match json.field("max_distance_from_center")? {
            Json::Number(_) => {
                let v = json.field("max_distance_from_center")?.as_i32()?;
                (v, v)
            }
            distance => (
                distance.field("horizontal")?.as_i32()?,
                distance.get("vertical").map_or(Ok(4064), Json::as_i32)?,
            ),
        };
        let (padding_bottom, padding_top) = match json.get("dimension_padding") {
            None => (0, 0),
            Some(Json::Number(n)) => (*n as i32, *n as i32),
            Some(padding) => (
                padding.get("bottom").map_or(Ok(0), Json::as_i32)?,
                padding.get("top").map_or(Ok(0), Json::as_i32)?,
            ),
        };
        Ok(JigsawConfig {
            start_pool: json.field("start_pool")?.as_str()?.to_string(),
            start_jigsaw_name: json
                .get("start_jigsaw_name")
                .map(|n| n.as_str().map(str::to_string))
                .transpose()?,
            max_depth: json.field("size")?.as_i32()?,
            start_height: HeightProvider::parse(json.field("start_height")?)?,
            use_expansion_hack: json.field("use_expansion_hack")?.as_bool()?,
            project_start_to_heightmap: json
                .get("project_start_to_heightmap")
                .map(|h| Heightmap::parse(h.as_str()?))
                .transpose()?,
            max_distance_horizontal: horizontal,
            max_distance_vertical: vertical,
            pool_aliases: json.get("pool_aliases").map_or(Ok(Vec::new()), |list| {
                list.as_array()?.iter().map(AliasBinding::parse).collect()
            })?,
            padding_bottom,
            padding_top,
            ignore_waterlogging: match json.get("liquid_settings").map(Json::as_str) {
                None => false,
                Some(name) => match name? {
                    "apply_waterlogging" => false,
                    "ignore_waterlogging" => true,
                    other => return Err(format!("unknown liquid settings {other}")),
                },
            },
        })
    }
}

/// A piece's jigsaw junction (`JigsawJunction`).
#[derive(Clone, Debug, PartialEq)]
pub struct Junction {
    pub source_x: i32,
    pub source_ground_y: i32,
    pub source_z: i32,
    pub delta_y: i32,
    pub dest_projection: Projection,
}

/// A `PoolElementStructurePiece`'s own fields.
#[derive(Clone, Debug)]
pub struct JigsawPiece {
    pub element: Arc<Element>,
    pub position: [i32; 3],
    pub ground_level_delta: i32,
    pub rotation: Rotation,
    pub junctions: Vec<Junction>,
    pub ignore_waterlogging: bool,
}

impl PartialEq for JigsawPiece {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.element, &other.element)
            && self.position == other.position
            && self.ground_level_delta == other.ground_level_delta
            && self.rotation == other.rotation
            && self.junctions == other.junctions
            && self.ignore_waterlogging == other.ignore_waterlogging
    }
}

impl JigsawPiece {
    pub fn save(&self, put: &mut dyn FnMut(&str, Nbt)) {
        put("PosX", Nbt::Int(self.position[0]));
        put("PosY", Nbt::Int(self.position[1]));
        put("PosZ", Nbt::Int(self.position[2]));
        put("ground_level_delta", Nbt::Int(self.ground_level_delta));
        put("pool_element", Nbt::Raw(self.element.nbt().to_string()));
        put("rotation", Nbt::string(rotation_name(self.rotation)));
        put(
            "junctions",
            Nbt::List(
                self.junctions
                    .iter()
                    .map(|j| {
                        Nbt::Compound(vec![
                            ("source_x".into(), Nbt::Int(j.source_x)),
                            ("source_ground_y".into(), Nbt::Int(j.source_ground_y)),
                            ("source_z".into(), Nbt::Int(j.source_z)),
                            ("delta_y".into(), Nbt::Int(j.delta_y)),
                            ("dest_proj".into(), Nbt::string(j.dest_projection.name())),
                        ])
                    })
                    .collect(),
            ),
        );
        if self.ignore_waterlogging {
            put("liquid_settings", Nbt::string("ignore_waterlogging"));
        }
    }
}

/// Free space for pieces: a box of cells minus placed boxes
/// (`VoxelShape`s built from block-aligned boxes).
struct Free {
    min: [i32; 3],
    max: [i32; 3],
    holes: Vec<BoundingBox>,
}

impl Free {
    fn of(b: &BoundingBox) -> Free {
        Free {
            min: [b.min_x, b.min_y, b.min_z],
            max: [b.max_x, b.max_y, b.max_z],
            holes: Vec::new(),
        }
    }

    /// Whether a box lies wholly in the free space (`!joinIsNotEmpty(free,
    /// box deflated by 0.25, ONLY_SECOND)`).
    fn contains(&self, b: &BoundingBox) -> bool {
        b.min_x >= self.min[0]
            && b.max_x <= self.max[0]
            && b.min_y >= self.min[1]
            && b.max_y <= self.max[1]
            && b.min_z >= self.min[2]
            && b.max_z <= self.max[2]
            && !self.holes.iter().any(|h| h.intersects(b))
    }
}

struct Placed {
    piece: JigsawPiece,
    bbox: BoundingBox,
}

/// `JigsawPlacement.addPieces` and the jigsaw structure's generation point.
pub fn generate(gc: &mut GenContext, config: &JigsawConfig) -> Result<Option<Vec<Piece>>, String> {
    let registry = gc.env.registry.clone();
    let heights = &gc.env.heights;
    let level_min_y = heights.level_min_y;
    let level_max_y = heights.level_min_y + heights.level_height - 1;
    let height = config.start_height.sample(
        &mut gc.random,
        HeightContext {
            min_y: level_min_y.max(heights.min_y),
            height: heights.level_height.min(heights.height),
            sea_level: heights.sea_level,
        },
    );
    let position = [gc.min_block_x(), height, gc.min_block_z()];
    let aliases = alias_lookup(&config.pool_aliases, position, gc.env.seed);
    let alias = |name: &str| -> String {
        aliases
            .get(name)
            .cloned()
            .unwrap_or_else(|| name.to_string())
    };

    let center_rotation = ROTATIONS[gc.random.next_int_bounded(4) as usize];
    let start_pool = registry.pool(&alias(&config.start_pool))?;
    let Some(center) = (if start_pool.templates.is_empty() {
        None
    } else {
        let index = gc
            .random
            .next_int_bounded(start_pool.templates.len() as i32) as usize;
        Some(start_pool.templates[index].clone())
    }) else {
        return Ok(None);
    };
    if matches!(*center, Element::Empty) {
        return Ok(None);
    }
    let anchored = match &config.start_jigsaw_name {
        None => position,
        Some(name) => {
            let jigsaws =
                center.shuffled_jigsaws(&registry, position, center_rotation, &mut gc.random)?;
            match jigsaws
                .into_iter()
                .find(|j| j.name.as_deref() == Some(name.as_str()))
            {
                Some(j) => j.pos,
                None => return Ok(None),
            }
        }
    };
    let local_anchor = [
        anchored[0] - position[0],
        anchored[1] - position[1],
        anchored[2] - position[2],
    ];
    let adjusted = [
        position[0] - local_anchor[0],
        position[1] - local_anchor[1],
        position[2] - local_anchor[2],
    ];
    let mut center_box = center.bounding_box(&registry, adjusted, center_rotation)?;
    let mut center_piece = JigsawPiece {
        element: center.clone(),
        position: adjusted,
        ground_level_delta: 1,
        rotation: center_rotation,
        junctions: Vec::new(),
        ignore_waterlogging: config.ignore_waterlogging,
    };
    let center_x = (center_box.max_x + center_box.min_x) / 2;
    let center_z = (center_box.max_z + center_box.min_z) / 2;
    let bottom_y = match config.project_start_to_heightmap {
        None => adjusted[1],
        Some(heightmap) => {
            if !gc.could_exist_in_column(center_x, center_z, level_min_y, level_max_y)? {
                return Ok(None);
            }
            position[1] + gc.base_height(center_x, center_z, heightmap)?
        }
    };
    let dy = bottom_y - (center_box.min_y + center_piece.ground_level_delta);
    center_box = center_box.moved(0, dy, 0);
    center_piece.position[1] += dy;
    if (config.padding_bottom, config.padding_top) != (0, 0)
        && (center_box.min_y < level_min_y + config.padding_bottom
            || center_box.max_y > level_max_y - config.padding_top)
    {
        return Ok(None);
    }
    let center_y = bottom_y + local_anchor[1];
    if !gc.is_valid_biome((center_x, center_y, center_z)) {
        return Ok(None);
    }
    let mut placed = vec![Placed {
        piece: center_piece,
        bbox: center_box,
    }];
    if config.max_depth <= 0 {
        // Vanilla's builder adds the pieces only when it places children.
        return Ok(Some(Vec::new()));
    }
    let h = config.max_distance_horizontal;
    let outer = Free {
        min: [
            center_x - h,
            (center_y - config.max_distance_vertical).max(level_min_y + config.padding_bottom),
            center_z - h,
        ],
        max: [
            center_x + h,
            (center_y + config.max_distance_vertical + 1).min(level_max_y + 1 - config.padding_top)
                - 1,
            center_z + h,
        ],
        holes: vec![center_box],
    };
    let mut placer = Placer {
        gc,
        registry: &registry,
        aliases: &alias,
        config,
        frees: vec![outer],
        queue: BTreeMap::new(),
    };
    placer.try_placing_children(&mut placed, 0, 0, 0)?;
    while let Some((piece, free, depth)) = placer.next() {
        placer.try_placing_children(&mut placed, piece, free, depth)?;
    }
    Ok(Some(
        placed
            .into_iter()
            .map(|p| Piece {
                kind: PieceKind::Jigsaw(p.piece),
                bbox: p.bbox,
                orientation: None,
                gen_depth: 0,
            })
            .collect(),
    ))
}

struct Placer<'a, 'b, 'c> {
    gc: &'a mut GenContext<'b>,
    registry: &'c StructureRegistry,
    aliases: &'c dyn Fn(&str) -> String,
    config: &'c JigsawConfig,
    frees: Vec<Free>,
    /// `SequencedPriorityIterator`: highest placement priority first, in
    /// insertion order within a priority.
    queue: BTreeMap<i32, VecDeque<(usize, usize, i32)>>,
}

impl Placer<'_, '_, '_> {
    fn next(&mut self) -> Option<(usize, usize, i32)> {
        let mut entry = self.queue.last_entry()?;
        let state = entry.get_mut().pop_front();
        if entry.get().is_empty() {
            entry.remove();
        }
        state
    }

    fn try_placing_children(
        &mut self,
        placed: &mut Vec<Placed>,
        source: usize,
        context_free: usize,
        depth: i32,
    ) -> Result<(), String> {
        let registry = self.registry;
        let source_element = placed[source].piece.element.clone();
        let source_position = placed[source].piece.position;
        let source_rotation = placed[source].piece.rotation;
        let source_projection = source_element.projection();
        let source_rigid = source_projection == Projection::Rigid;
        let source_bb = placed[source].bbox;
        let source_box_y = source_bb.min_y;
        let mut source_free: Option<usize> = None;
        let jigsaws = source_element.shuffled_jigsaws(
            registry,
            source_position,
            source_rotation,
            &mut self.gc.random,
        )?;
        'jigsaws: for source_jigsaw in &jigsaws {
            let step = source_jigsaw.front.step();
            let source_pos = source_jigsaw.pos;
            let target_pos = [
                source_pos[0] + step[0],
                source_pos[1] + step[1],
                source_pos[2] + step[2],
            ];
            let source_local_y = source_pos[1] - source_box_y;
            let mut source_base_height: Option<i32> = None;
            let pool_name = (self.aliases)(&source_jigsaw.pool);
            let Some(pool) = registry.pools.get(&pool_name) else {
                continue;
            };
            if pool.templates.is_empty() && pool_name != EMPTY_POOL {
                continue;
            }
            let fallback = registry.pool(&pool.fallback)?;
            if fallback.templates.is_empty() && pool.fallback != EMPTY_POOL {
                continue;
            }
            let inside = source_bb.is_inside(target_pos[0], target_pos[1], target_pos[2]);
            let children_free = if inside {
                *source_free.get_or_insert_with(|| {
                    self.frees.push(Free::of(&source_bb));
                    self.frees.len() - 1
                })
            } else {
                context_free
            };
            let mut targets = Vec::new();
            if depth != self.config.max_depth {
                targets.extend(pool.shuffled(&mut self.gc.random));
            }
            targets.extend(fallback.shuffled(&mut self.gc.random));
            let priority = source_jigsaw.placement_priority;
            for target in targets {
                if matches!(*target, Element::Empty) {
                    break;
                }
                let mut rotations = ROTATIONS;
                shuffle(&mut rotations, &mut self.gc.random);
                for rotation in rotations {
                    let target_jigsaws = target.shuffled_jigsaws(
                        registry,
                        [0, 0, 0],
                        rotation,
                        &mut self.gc.random,
                    )?;
                    let hack_box = target.bounding_box(registry, [0, 0, 0], rotation)?;
                    let mut expand_to = 0;
                    if self.config.use_expansion_hack && hack_box.y_span() <= 16 {
                        for j in &target_jigsaws {
                            let s = j.front.step();
                            if !hack_box.is_inside(
                                j.pos[0] + s[0],
                                j.pos[1] + s[1],
                                j.pos[2] + s[2],
                            ) {
                                continue;
                            }
                            let child = registry.pools.get(&(self.aliases)(&j.pool));
                            let child_size = match child {
                                Some(p) => p.max_size(registry)?,
                                None => 0,
                            };
                            let fallback_size = match child {
                                Some(p) => registry.pool(&p.fallback)?.max_size(registry)?,
                                None => 0,
                            };
                            expand_to = expand_to.max(child_size.max(fallback_size));
                        }
                    }
                    for target_jigsaw in &target_jigsaws {
                        if !can_attach(source_jigsaw, target_jigsaw) {
                            continue;
                        }
                        let local = target_jigsaw.pos;
                        let raw_position = [
                            target_pos[0] - local[0],
                            target_pos[1] - local[1],
                            target_pos[2] - local[2],
                        ];
                        let raw_bb = target.bounding_box(registry, raw_position, rotation)?;
                        let target_projection = target.projection();
                        let target_rigid = target_projection == Projection::Rigid;
                        let delta_y = source_local_y - local[1] + source_jigsaw.front.step()[1];
                        let target_box_y = if source_rigid && target_rigid {
                            source_box_y + delta_y
                        } else {
                            self.base_height(&mut source_base_height, source_pos)? - local[1]
                        };
                        let y_offset = target_box_y - raw_bb.min_y;
                        let mut target_bb = raw_bb.moved(0, y_offset, 0);
                        let target_position =
                            [raw_position[0], raw_position[1] + y_offset, raw_position[2]];
                        if expand_to > 0 {
                            let size = (expand_to + 1).max(target_bb.max_y - target_bb.min_y);
                            target_bb.max_y = target_bb.max_y.max(target_bb.min_y + size);
                        }
                        if !self.frees[children_free].contains(&target_bb) {
                            continue;
                        }
                        self.frees[children_free].holes.push(target_bb);
                        let source_ground = placed[source].piece.ground_level_delta;
                        let target_ground = if target_rigid {
                            source_ground - delta_y
                        } else {
                            1
                        };
                        let junction_y = if source_rigid {
                            source_box_y + source_local_y
                        } else if target_rigid {
                            target_box_y + local[1]
                        } else {
                            self.base_height(&mut source_base_height, source_pos)? + delta_y / 2
                        };
                        placed[source].piece.junctions.push(Junction {
                            source_x: target_pos[0],
                            source_ground_y: junction_y - source_local_y + source_ground,
                            source_z: target_pos[2],
                            delta_y,
                            dest_projection: target_projection,
                        });
                        placed.push(Placed {
                            piece: JigsawPiece {
                                element: target.clone(),
                                position: target_position,
                                ground_level_delta: target_ground,
                                rotation,
                                junctions: vec![Junction {
                                    source_x: source_pos[0],
                                    source_ground_y: junction_y - local[1] + target_ground,
                                    source_z: source_pos[2],
                                    delta_y: -delta_y,
                                    dest_projection: source_projection,
                                }],
                                ignore_waterlogging: self.config.ignore_waterlogging,
                            },
                            bbox: target_bb,
                        });
                        if depth < self.config.max_depth {
                            self.queue.entry(priority).or_default().push_back((
                                placed.len() - 1,
                                children_free,
                                depth + 1,
                            ));
                        }
                        continue 'jigsaws;
                    }
                }
            }
        }
        Ok(())
    }

    /// The source jigsaw's first free height (`WORLD_SURFACE_WG`), computed
    /// once per jigsaw.
    fn base_height(&self, cache: &mut Option<i32>, pos: [i32; 3]) -> Result<i32, String> {
        if let Some(h) = *cache {
            return Ok(h);
        }
        let h = self
            .gc
            .base_height(pos[0], pos[2], Heightmap::WorldSurfaceWg)?;
        *cache = Some(h);
        Ok(h)
    }
}
