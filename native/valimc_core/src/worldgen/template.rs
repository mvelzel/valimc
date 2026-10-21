//! Structure templates (VMC-025c): the templates features place (fossils,
//! the desert well, sulfur springs) as vanilla loads them
//! (`StructureTemplateOracle`, `priv/worldgen/templates.json`), processor
//! lists (`processor_lists.json`), `StructureTemplate.placeInWorld` with its
//! processors, waterlogging and shape updates, and the template and fossil
//! features.

use std::collections::HashMap;
use std::sync::Arc;

use super::blocks::{
    BlockSet, BlockTable, Heightmap, FLUID_LAVA, FLUID_WATER, LIQUID_CONTAINER, SIMPLE_WATERLOGGED,
};
use super::feature::Decoration;
use super::json::Json;
use super::predicate::{offset, RuleTest};
use super::random::{position_seed, Random};
use super::region::Region;
use super::tree::{Shape, EAST, NORTH, SOUTH, WEST};

/// A template block's block entity data, with what processors added.
#[derive(Clone, Debug, Default)]
pub struct EntityNbt {
    pub loot_table: Option<String>,
    pub loot_seed: Option<i64>,
}

impl EntityNbt {
    /// The fields decoration reads from a template block's SNBT.
    fn parse(snbt: &str) -> EntityNbt {
        let after = |key: &str| {
            let at = snbt.find(&format!("{key}:"))?;
            Some(&snbt[at + key.len() + 1..])
        };
        let loot_table = after("LootTable")
            .and_then(|rest| rest.strip_prefix('"'))
            .and_then(|rest| rest.split('"').next())
            .map(str::to_string);
        let loot_seed = after("LootTableSeed").and_then(|rest| {
            let digits: String = rest
                .chars()
                .take_while(|c| c.is_ascii_digit() || *c == '-')
                .collect();
            digits.parse().ok()
        });
        EntityNbt {
            loot_table,
            loot_seed,
        }
    }
}

#[derive(Clone, Debug)]
pub struct TemplateBlock {
    pub pos: [i32; 3],
    pub state: u16,
    pub nbt: Option<EntityNbt>,
}

#[derive(Debug)]
pub struct Template {
    pub size: [i32; 3],
    pub palettes: Vec<Vec<TemplateBlock>>,
    pub entities: usize,
}

impl Template {
    /// `getSize(rotation)`.
    pub fn size(&self, rotation: Rotation) -> [i32; 3] {
        match rotation {
            Rotation::Clockwise90 | Rotation::Counterclockwise90 => {
                [self.size[2], self.size[1], self.size[0]]
            }
            _ => self.size,
        }
    }

    /// `getBoundingBox(settings, position)`.
    pub fn bounding_box(&self, settings: &PlaceSettings, position: [i32; 3]) -> BoundingBox {
        let delta = [self.size[0] - 1, self.size[1] - 1, self.size[2] - 1];
        let a = transform(
            [0, 0, 0],
            settings.mirror,
            settings.rotation,
            settings.pivot,
        );
        let b = transform(delta, settings.mirror, settings.rotation, settings.pivot);
        BoundingBox::from_corners(a, b).moved(position)
    }

    /// `getZeroPositionWithTransform`.
    pub fn zero_position(&self, zero: [i32; 3], mirror: Mirror, rotation: Rotation) -> [i32; 3] {
        let (sx, sz) = (self.size[0] - 1, self.size[2] - 1);
        let mx = if mirror == Mirror::FrontBack { sx } else { 0 };
        let mz = if mirror == Mirror::LeftRight { sz } else { 0 };
        let d = match rotation {
            Rotation::Counterclockwise90 => [mz, 0, sx - mx],
            Rotation::Clockwise90 => [sz - mz, 0, mx],
            Rotation::Clockwise180 => [sx - mx, 0, sz - mz],
            Rotation::None => [mx, 0, mz],
        };
        offset(zero, d)
    }
}

/// `Rotation`, in vanilla's order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Rotation {
    None,
    Clockwise90,
    Clockwise180,
    Counterclockwise90,
}

pub const ROTATIONS: [Rotation; 4] = [
    Rotation::None,
    Rotation::Clockwise90,
    Rotation::Clockwise180,
    Rotation::Counterclockwise90,
];

impl Rotation {
    fn parse(name: &str) -> Result<Rotation, String> {
        Ok(match name {
            "none" => Rotation::None,
            "clockwise_90" => Rotation::Clockwise90,
            "180" => Rotation::Clockwise180,
            "counterclockwise_90" => Rotation::Counterclockwise90,
            other => return Err(format!("unknown rotation {other}")),
        })
    }

    /// `rotate(Direction)` of a horizontal direction.
    fn rotate(self, d: usize) -> usize {
        let clockwise = super::tree::clockwise;
        match self {
            Rotation::None => d,
            Rotation::Clockwise90 => clockwise(d),
            Rotation::Clockwise180 => d ^ 1,
            Rotation::Counterclockwise90 => clockwise(d) ^ 1,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mirror {
    None,
    LeftRight,
    FrontBack,
}

/// `StructureTemplate.transform` of a block position.
pub fn transform(pos: [i32; 3], mirror: Mirror, rotation: Rotation, pivot: [i32; 3]) -> [i32; 3] {
    let [mut x, y, mut z] = pos;
    match mirror {
        Mirror::LeftRight => z = -z,
        Mirror::FrontBack => x = -x,
        Mirror::None => {}
    }
    let (px, pz) = (pivot[0], pivot[2]);
    match rotation {
        Rotation::Counterclockwise90 => [px - pz + z, y, px + pz - x],
        Rotation::Clockwise90 => [px + pz - z, y, pz - px + x],
        Rotation::Clockwise180 => [px + px - x, y, pz + pz - z],
        Rotation::None => [x, y, z],
    }
}

/// `BoundingBox`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BoundingBox {
    pub min: [i32; 3],
    pub max: [i32; 3],
}

impl BoundingBox {
    pub fn from_corners(a: [i32; 3], b: [i32; 3]) -> BoundingBox {
        BoundingBox {
            min: [a[0].min(b[0]), a[1].min(b[1]), a[2].min(b[2])],
            max: [a[0].max(b[0]), a[1].max(b[1]), a[2].max(b[2])],
        }
    }

    pub fn moved(self, by: [i32; 3]) -> BoundingBox {
        BoundingBox {
            min: offset(self.min, by),
            max: offset(self.max, by),
        }
    }

    pub fn inside(&self, p: [i32; 3]) -> bool {
        (0..3).all(|i| p[i] >= self.min[i] && p[i] <= self.max[i])
    }

    pub fn corners(&self) -> [[i32; 3]; 8] {
        let (a, b) = (self.min, self.max);
        [
            [a[0], a[1], a[2]],
            [a[0], a[1], b[2]],
            [a[0], b[1], a[2]],
            [a[0], b[1], b[2]],
            [b[0], a[1], a[2]],
            [b[0], a[1], b[2]],
            [b[0], b[1], a[2]],
            [b[0], b[1], b[2]],
        ]
    }
}

/// A rule's block entity modifier (`RuleBlockEntityModifier`).
#[derive(Debug)]
pub enum EntityModifier {
    Passthrough,
    AppendLoot(String),
}

#[derive(Debug)]
pub struct ProcessorRule {
    input: RuleTest,
    location: RuleTest,
    output: u16,
    modifier: EntityModifier,
}

/// A structure processor.
#[derive(Debug)]
pub enum Processor {
    BlockRot {
        rottable: Option<BlockSet>,
        integrity: f32,
    },
    Protected(BlockSet),
    Rule(Vec<ProcessorRule>),
}

impl Processor {
    fn parse(json: &Json, table: &BlockTable) -> Result<Processor, String> {
        Ok(match json.field("processor_type")?.as_str()? {
            "minecraft:block_rot" => Processor::BlockRot {
                rottable: json
                    .get("rottable_blocks")
                    .map(|b| table.block_set(b))
                    .transpose()?,
                integrity: json.field("integrity")?.as_f64()? as f32,
            },
            "minecraft:protected_blocks" => {
                Processor::Protected(table.block_set(json.field("value")?)?)
            }
            "minecraft:rule" => Processor::Rule(
                json.field("rules")?
                    .as_array()?
                    .iter()
                    .map(|r| {
                        if let Some(p) = r.get("position_predicate") {
                            if p.field("predicate_type")?.as_str()? != "minecraft:always_true" {
                                return Err("position predicates are not implemented".to_string());
                            }
                        }
                        let modifier = match r.get("block_entity_modifier") {
                            None => EntityModifier::Passthrough,
                            Some(m) => match m.field("type")?.as_str()? {
                                "minecraft:passthrough" => EntityModifier::Passthrough,
                                "minecraft:append_loot" => EntityModifier::AppendLoot(
                                    m.field("loot_table")?.as_str()?.to_string(),
                                ),
                                other => return Err(format!("block entity modifier {other}")),
                            },
                        };
                        Ok(ProcessorRule {
                            input: RuleTest::parse(r.field("input_predicate")?, table)?,
                            location: RuleTest::parse(r.field("location_predicate")?, table)?,
                            output: table.state(r.field("output_state")?)?,
                            modifier,
                        })
                    })
                    .collect::<Result<_, String>>()?,
            ),
            other => return Err(format!("structure processor {other} is not implemented")),
        })
    }

    /// `processBlock`: the block as processed, or `None` when dropped.
    fn process(
        &self,
        table: &BlockTable,
        region: &mut Region,
        info: BlockInfo,
        random: &mut Random,
    ) -> Option<BlockInfo> {
        match self {
            Processor::BlockRot {
                rottable,
                integrity,
            } => {
                let rots = rottable
                    .as_ref()
                    .is_none_or(|set| table.in_tag(info.state, set));
                if rots && random.next_float() > *integrity {
                    None
                } else {
                    Some(info)
                }
            }
            Processor::Protected(set) => {
                let current = region.get(info.pos);
                (!table.in_tag(current, set)).then_some(info)
            }
            Processor::Rule(rules) => {
                let p = info.pos;
                let mut rule_random = Random::legacy(position_seed(p[0], p[1], p[2]));
                for rule in rules {
                    if !rule.input.test(table, info.state, p, &mut rule_random) {
                        continue;
                    }
                    let current = region.get(p);
                    if !rule.location.test(table, current, p, &mut rule_random) {
                        continue;
                    }
                    let nbt = match &rule.modifier {
                        EntityModifier::Passthrough => info.nbt,
                        EntityModifier::AppendLoot(table_id) => {
                            let mut nbt = info.nbt.unwrap_or_default();
                            nbt.loot_table = Some(table_id.clone());
                            nbt.loot_seed = Some(rule_random.next_long());
                            Some(nbt)
                        }
                    };
                    return Some(BlockInfo {
                        pos: p,
                        state: rule.output,
                        nbt,
                    });
                }
                Some(info)
            }
        }
    }
}

/// Parsed templates, processor lists and state transforms.
#[derive(Debug, Default)]
pub struct Templates {
    templates: HashMap<String, Arc<Template>>,
    lists: HashMap<String, Arc<Vec<Processor>>>,
    /// Per state: clockwise 90, 180, counterclockwise 90, mirrored left-right
    /// and front-back.
    transforms: HashMap<u16, [u16; 5]>,
}

impl Templates {
    pub fn parse(templates: &Json, lists: &Json, table: &BlockTable) -> Result<Templates, String> {
        let mut out = Templates::default();
        for (id, entry) in templates.field("templates")?.entries()? {
            let size = entry.field("size")?.as_array()?;
            let palettes = entry
                .field("palettes")?
                .as_array()?
                .iter()
                .map(|palette| {
                    palette
                        .as_array()?
                        .iter()
                        .map(|row| {
                            let row = row.as_array()?;
                            Ok(TemplateBlock {
                                pos: [row[0].as_i32()?, row[1].as_i32()?, row[2].as_i32()?],
                                state: row[3].as_i32()? as u16,
                                nbt: match row.get(4) {
                                    Some(snbt) => Some(EntityNbt::parse(snbt.as_str()?)),
                                    None => None,
                                },
                            })
                        })
                        .collect::<Result<Vec<_>, String>>()
                })
                .collect::<Result<Vec<_>, String>>()?;
            out.templates.insert(
                id.clone(),
                Arc::new(Template {
                    size: [size[0].as_i32()?, size[1].as_i32()?, size[2].as_i32()?],
                    palettes,
                    entities: entry.field("entities")?.as_i32()? as usize,
                }),
            );
        }
        for row in templates.field("transforms")?.as_array()? {
            let row = row.as_array()?;
            let id = |i: usize| row[i].as_i32().map(|v| v as u16);
            out.transforms
                .insert(id(0)?, [id(1)?, id(2)?, id(3)?, id(4)?, id(5)?]);
        }
        for (id, list) in lists.entries()? {
            // A list that this slice cannot place stays out; naming it fails.
            if let Ok(processors) = Self::parse_list(list, table) {
                out.lists.insert(id.clone(), Arc::new(processors));
            }
        }
        Ok(out)
    }

    fn parse_list(json: &Json, table: &BlockTable) -> Result<Vec<Processor>, String> {
        let items = match json {
            Json::Array(_) => json,
            _ => json.field("processors")?,
        };
        items
            .as_array()?
            .iter()
            .map(|p| Processor::parse(p, table))
            .collect()
    }

    /// A processor list: an identifier or an inline list.
    pub fn processors(
        &self,
        json: &Json,
        table: &BlockTable,
    ) -> Result<Arc<Vec<Processor>>, String> {
        match json {
            Json::String(id) => self
                .lists
                .get(id)
                .cloned()
                .ok_or_else(|| format!("processor list {id} is not available")),
            other => Ok(Arc::new(Self::parse_list(other, table)?)),
        }
    }

    pub fn template(&self, id: &str) -> Result<Arc<Template>, String> {
        self.templates
            .get(id)
            .cloned()
            .ok_or_else(|| format!("no structure template {id}"))
    }

    /// `state.mirror(mirror).rotate(rotation)`; states without a row are
    /// their own transforms.
    pub fn transform_state(&self, state: u16, mirror: Mirror, rotation: Rotation) -> u16 {
        if mirror == Mirror::None && rotation == Rotation::None {
            return state;
        }
        let mirrored = match (mirror, self.transforms.get(&state)) {
            (Mirror::LeftRight, Some(row)) => row[3],
            (Mirror::FrontBack, Some(row)) => row[4],
            _ => state,
        };
        match (rotation, self.transforms.get(&mirrored)) {
            (Rotation::Clockwise90, Some(row)) => row[0],
            (Rotation::Clockwise180, Some(row)) => row[1],
            (Rotation::Counterclockwise90, Some(row)) => row[2],
            _ => mirrored,
        }
    }
}

/// `StructurePlaceSettings`, with the settings features use.
pub struct PlaceSettings {
    pub mirror: Mirror,
    pub rotation: Rotation,
    pub pivot: [i32; 3],
    pub bounding_box: Option<BoundingBox>,
    pub processors: Arc<Vec<Processor>>,
}

/// `StructureTemplate.StructureBlockInfo`.
#[derive(Clone, Debug)]
struct BlockInfo {
    pos: [i32; 3],
    state: u16,
    nbt: Option<EntityNbt>,
}

/// A fluid as template placement reads it: source water and lava matter.
fn is_source(fluid: u8) -> bool {
    fluid == FLUID_WATER || fluid == FLUID_LAVA
}

impl Templates {
    /// `StructureTemplate.placeInWorld` with the feature's random as the
    /// settings' random.
    #[allow(clippy::too_many_arguments)]
    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        template: &Template,
        position: [i32; 3],
        settings: &PlaceSettings,
        random: &mut Random,
        update_mode: i32,
    ) -> Result<bool, String> {
        let table = d.table.as_ref();
        if template.palettes.is_empty() {
            return Ok(false);
        }
        let palette =
            &template.palettes[random.next_int_bounded(template.palettes.len() as i32) as usize];
        if (palette.is_empty() && template.entities == 0) || template.size.iter().any(|&s| s < 1) {
            return Ok(false);
        }
        if template.entities > 0 {
            return Err("template entities are not implemented".into());
        }
        // `processBlockInfos`: none of these processors reads the whole piece,
        // so only blocks inside the bounding box are processed.
        let mut processed = Vec::with_capacity(palette.len());
        for block in palette {
            let pos = offset(
                transform(
                    block.pos,
                    settings.mirror,
                    settings.rotation,
                    settings.pivot,
                ),
                position,
            );
            if settings.bounding_box.is_some_and(|b| !b.inside(pos)) {
                continue;
            }
            let mut info = Some(BlockInfo {
                pos,
                state: block.state,
                nbt: block.nbt.clone(),
            });
            for processor in settings.processors.iter() {
                let Some(current) = info else {
                    break;
                };
                info = processor.process(table, region, current, random);
            }
            if let Some(info) = info {
                processed.push(info);
            }
        }
        let barrier = table.default_state("barrier")?;
        let mut to_fill: Vec<[i32; 3]> = Vec::new();
        let mut locked: Vec<[i32; 3]> = Vec::new();
        let mut placed: Vec<[i32; 3]> = Vec::new();
        let mut min = [i32::MAX; 3];
        let mut max = [i32::MIN; 3];
        for info in processed {
            let pos = info.pos;
            if settings.bounding_box.is_some_and(|b| !b.inside(pos)) {
                continue;
            }
            let previous = table.fluid(region.get(pos));
            let state = self.transform_state(info.state, settings.mirror, settings.rotation);
            if info.nbt.is_some() {
                region.set(pos, barrier, 820);
            }
            if !region.set(pos, state, update_mode) {
                continue;
            }
            for i in 0..3 {
                min[i] = min[i].min(pos[i]);
                max[i] = max[i].max(pos[i]);
            }
            placed.push(pos);
            if let Some(nbt) = &info.nbt {
                if let Some(be) = region.block_entity(pos)? {
                    let mut seed = nbt.loot_seed;
                    if matches!(be.kind, "minecraft:chest" | "minecraft:trapped_chest") {
                        seed = Some(random.next_long());
                    }
                    be.loot_table = nbt.loot_table.clone();
                    be.loot_seed = seed.unwrap_or(0);
                }
            }
            if is_source(table.fluid(state)) {
                locked.push(pos);
            } else if table.flag(state, LIQUID_CONTAINER) {
                self.place_liquid(table, region, pos, state, previous);
                if !is_source(previous) {
                    to_fill.push(pos);
                }
            }
        }
        let mut filled = true;
        while filled && !to_fill.is_empty() {
            filled = false;
            let mut i = 0;
            while i < to_fill.len() {
                let pos = to_fill[i];
                let mut fluid = table.fluid(region.get(pos));
                for dir in [1, NORTH, EAST, SOUTH, WEST] {
                    if is_source(fluid) {
                        break;
                    }
                    let n = offset(pos, super::tree::STEP[dir]);
                    let neighbour = table.fluid(region.get(n));
                    if is_source(neighbour) && !locked.contains(&n) {
                        fluid = neighbour;
                    }
                }
                if is_source(fluid) {
                    let state = region.get(pos);
                    if table.flag(state, LIQUID_CONTAINER) {
                        self.place_liquid(table, region, pos, state, fluid);
                        filled = true;
                        to_fill.remove(i);
                        continue;
                    }
                }
                i += 1;
            }
        }
        if min[0] <= max[0] {
            let mut shape = Shape::new(min, max);
            for pos in &placed {
                shape.fill(*pos);
            }
            super::tree::update_shape_at_edge(d, region, &shape)?;
            for pos in placed {
                let state = region.get(pos);
                let mut new_state = state;
                for dir in [WEST, EAST, NORTH, SOUTH, 0, 1] {
                    new_state = d.update_shape(region, new_state, pos, dir, None)?;
                }
                if state != new_state {
                    region.set(pos, new_state, (update_mode & !1) | 16);
                }
            }
        }
        Ok(true)
    }

    /// `LiquidBlockContainer.placeLiquid`: a simple waterlogged block takes
    /// source water; other containers take nothing.
    fn place_liquid(
        &self,
        table: &BlockTable,
        region: &mut Region,
        pos: [i32; 3],
        state: u16,
        fluid: u8,
    ) {
        if !table.flag(state, SIMPLE_WATERLOGGED) || fluid != FLUID_WATER {
            return;
        }
        if table.value(state, "waterlogged") != Some("false") {
            return;
        }
        if let Some(wet) = table.with(state, "waterlogged", "true") {
            region.set(pos, wet, 3);
            region.schedule_fluid_tick(pos, FLUID_WATER);
        }
    }
}

/// `TemplateFeature`.
#[derive(Debug)]
pub struct TemplateFeature {
    entries: Vec<(String, Vec<Rotation>, i32)>,
    total: i32,
    processors: Arc<Vec<Processor>>,
}

impl TemplateFeature {
    pub fn parse(
        json: &Json,
        table: &BlockTable,
        templates: &Templates,
    ) -> Result<TemplateFeature, String> {
        let mut entries = Vec::new();
        let mut total = 0;
        for entry in json.field("templates")?.as_array()? {
            let data = entry.field("data")?;
            let id = data.field("id")?.as_str()?.to_string();
            templates.template(&id)?;
            let rotations = match data.get("rotations") {
                Some(list) => list
                    .as_array()?
                    .iter()
                    .map(|r| Rotation::parse(r.as_str()?))
                    .collect::<Result<_, _>>()?,
                None => ROTATIONS.to_vec(),
            };
            let weight = entry.field("weight")?.as_i32()?;
            total += weight;
            entries.push((id, rotations, weight));
        }
        Ok(TemplateFeature {
            entries,
            total,
            processors: match json.get("processors") {
                Some(p) => templates.processors(p, table)?,
                None => Arc::new(Vec::new()),
            },
        })
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let mut pick = random.next_int_bounded(self.total);
        let (id, rotations, _) = self
            .entries
            .iter()
            .find(|(_, _, w)| {
                pick -= w;
                pick < 0
            })
            .ok_or("template weights")?;
        let rotation = rotations[random.next_int_bounded(rotations.len() as i32) as usize];
        let templates = d.templates()?;
        let template = templates.template(id)?;
        let step = |dir: usize, n: i32| {
            let s = super::tree::STEP[rotation.rotate(dir)];
            [s[0] * n, s[1] * n, s[2] * n]
        };
        let pos = offset(
            offset(origin, step(WEST, template.size[0] / 2)),
            step(NORTH, template.size[2] / 2),
        );
        let settings = PlaceSettings {
            mirror: Mirror::None,
            rotation,
            pivot: [0, 0, 0],
            bounding_box: None,
            processors: self.processors.clone(),
        };
        templates.place(d, region, &template, pos, &settings, random, 3)
    }
}

/// `FossilFeature`.
#[derive(Debug)]
pub struct Fossil {
    fossils: Vec<String>,
    overlays: Vec<String>,
    fossil_processors: Arc<Vec<Processor>>,
    overlay_processors: Arc<Vec<Processor>>,
    max_empty_corners: i32,
    water: u16,
    lava: u16,
}

impl Fossil {
    pub fn parse(json: &Json, table: &BlockTable, templates: &Templates) -> Result<Fossil, String> {
        let ids = |k: &str| -> Result<Vec<String>, String> {
            json.field(k)?
                .as_array()?
                .iter()
                .map(|t| {
                    let id = t.as_str()?.to_string();
                    templates.template(&id)?;
                    Ok(id)
                })
                .collect()
        };
        Ok(Fossil {
            fossils: ids("fossil_structures")?,
            overlays: ids("overlay_structures")?,
            fossil_processors: templates.processors(json.field("fossil_processors")?, table)?,
            overlay_processors: templates.processors(json.field("overlay_processors")?, table)?,
            max_empty_corners: json.field("max_empty_corners_allowed")?.as_i32()?,
            water: table.block("water")?,
            lava: table.block("lava")?,
        })
    }

    pub fn place(
        &self,
        d: &Decoration,
        region: &mut Region,
        random: &mut Random,
        origin: [i32; 3],
    ) -> Result<bool, String> {
        let table = d.table.as_ref();
        let rotation = ROTATIONS[random.next_int_bounded(4) as usize];
        let index = random.next_int_bounded(self.fossils.len() as i32) as usize;
        let templates = d.templates()?;
        let base = templates.template(&self.fossils[index])?;
        let overlay = templates.template(&self.overlays[index])?;
        let (cx, cz) = (origin[0] >> 4, origin[2] >> 4);
        let min_y = region.min_y();
        let max_y = min_y + region.height() - 1;
        let bounding_box = BoundingBox {
            min: [cx * 16 - 16, min_y, cz * 16 - 16],
            max: [cx * 16 + 15 + 16, max_y, cz * 16 + 15 + 16],
        };
        let mut settings = PlaceSettings {
            mirror: Mirror::None,
            rotation,
            pivot: [0, 0, 0],
            bounding_box: Some(bounding_box),
            processors: Arc::new(Vec::new()),
        };
        let size = base.size(rotation);
        let low = offset(origin, [-size[0] / 2, 0, -size[2] / 2]);
        let mut lowest = origin[1];
        for x in 0..size[0] {
            for z in 0..size[2] {
                lowest =
                    lowest.min(region.height_at(Heightmap::OceanFloorWg, low[0] + x, low[2] + z));
            }
        }
        let target_y = (lowest - 15 - random.next_int_bounded(10)).max(min_y + 10);
        let target = base.zero_position([low[0], target_y, low[2]], Mirror::None, rotation);
        let empty = base
            .bounding_box(&settings, target)
            .corners()
            .iter()
            .filter(|&&c| {
                let s = region.get(c);
                let b = table.block_of(s);
                table.is_air(s) || b == self.lava || b == self.water
            })
            .count() as i32;
        if empty > self.max_empty_corners {
            return Ok(false);
        }
        settings.processors = self.fossil_processors.clone();
        templates.place(d, region, &base, target, &settings, random, 260)?;
        settings.processors = self.overlay_processors.clone();
        templates.place(d, region, &overlay, target, &settings, random, 260)?;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transforms_follow_vanilla() {
        let p = [2, 5, 3];
        let pivot = [0, 0, 0];
        assert_eq!(transform(p, Mirror::None, Rotation::None, pivot), p);
        assert_eq!(
            transform(p, Mirror::None, Rotation::Clockwise90, pivot),
            [-3, 5, 2]
        );
        assert_eq!(
            transform(p, Mirror::None, Rotation::Clockwise180, pivot),
            [-2, 5, -3]
        );
        assert_eq!(
            transform(p, Mirror::None, Rotation::Counterclockwise90, pivot),
            [3, 5, -2]
        );
        assert_eq!(
            transform(p, Mirror::LeftRight, Rotation::None, pivot),
            [2, 5, -3]
        );
        assert_eq!(
            transform(p, Mirror::FrontBack, Rotation::None, pivot),
            [-2, 5, 3]
        );
        // Rotations of horizontal directions (north, east, south, west).
        assert_eq!(Rotation::Clockwise90.rotate(NORTH), EAST);
        assert_eq!(Rotation::Counterclockwise90.rotate(NORTH), WEST);
        assert_eq!(Rotation::Counterclockwise90.rotate(WEST), SOUTH);
        assert_eq!(Rotation::Clockwise180.rotate(EAST), WEST);
    }

    #[test]
    fn zero_positions_and_boxes() {
        let template = Template {
            size: [3, 2, 5],
            palettes: vec![],
            entities: 0,
        };
        let zero = [10, 0, 20];
        assert_eq!(
            template.zero_position(zero, Mirror::None, Rotation::None),
            zero
        );
        assert_eq!(
            template.zero_position(zero, Mirror::None, Rotation::Clockwise90),
            [14, 0, 20]
        );
        assert_eq!(
            template.zero_position(zero, Mirror::None, Rotation::Clockwise180),
            [12, 0, 24]
        );
        assert_eq!(
            template.zero_position(zero, Mirror::None, Rotation::Counterclockwise90),
            [10, 0, 22]
        );
        let settings = PlaceSettings {
            mirror: Mirror::None,
            rotation: Rotation::Clockwise90,
            pivot: [0, 0, 0],
            bounding_box: None,
            processors: Arc::new(Vec::new()),
        };
        let b = template.bounding_box(&settings, [14, 0, 20]);
        assert_eq!(b.min, [10, 0, 20]);
        assert_eq!(b.max, [14, 1, 22]);
        assert_eq!(template.size(Rotation::Clockwise90), [5, 2, 3]);
    }

    #[test]
    fn entity_nbt_reads_loot() {
        let nbt = EntityNbt::parse(
            r#"{LootTable:"minecraft:chests/x",LootTableSeed:-42L,id:"minecraft:chest"}"#,
        );
        assert_eq!(nbt.loot_table.as_deref(), Some("minecraft:chests/x"));
        assert_eq!(nbt.loot_seed, Some(-42));
        let empty = EntityNbt::parse(r#"{components:{},id:"minecraft:brushable_block"}"#);
        assert!(empty.loot_table.is_none() && empty.loot_seed.is_none());
    }
}
