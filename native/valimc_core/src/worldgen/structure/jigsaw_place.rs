//! Jigsaw pieces placed into chunks (VMC-025f3): `PoolElementStructurePiece`
//! places its pool element: single elements their template (jigsaw blocks
//! replaced, the element's processors and the projection's), lists each of
//! theirs, feature elements their placed feature.

use super::super::blocks::{BlockSet, Heightmap};
use super::super::template::{
    BoundingBox as TemplateBox, Mirror, PlaceSettings, Processor, Rotation,
};
use super::jigsaw::{Element, Projection};
use super::piece::{Piece, PieceKind};
use super::place::Ctx;

/// A jigsaw piece's `postProcess`.
pub fn post_process(piece: &mut Piece, c: &mut Ctx) -> Result<(), String> {
    let PieceKind::Jigsaw(j) = &piece.kind else {
        return Err("not a jigsaw piece".into());
    };
    let element = j.element.clone();
    place(&element, c, j.position, j.rotation, !j.ignore_waterlogging)?;
    Ok(())
}

/// `StructurePoolElement.place`; whether it placed anything.
fn place(
    element: &Element,
    c: &mut Ctx,
    position: [i32; 3],
    rotation: Rotation,
    waterlogging: bool,
) -> Result<bool, String> {
    match element {
        Element::Empty => Ok(true),
        Element::List { elements, .. } => {
            for e in elements {
                if !place(e, c, position, rotation, waterlogging)? {
                    return Ok(false);
                }
            }
            Ok(true)
        }
        Element::Feature { feature, .. } => {
            let d = c.placer.decoration;
            let placed = d
                .placed
                .get(feature)
                .cloned()
                .ok_or_else(|| format!("placed feature {feature} is not available"))?;
            placed.place(d, c.region, c.random, position, false)
        }
        Element::Single {
            location,
            projection,
            legacy,
            processors,
            ..
        } => {
            let templates = c.placer.templates.ok_or("no structure templates")?;
            let template = templates.template(location)?;
            let table = c.placer.table;
            let ignore = |names: &[&str]| -> Result<Processor, String> {
                let blocks = names
                    .iter()
                    .map(|n| table.block(n))
                    .collect::<Result<Vec<_>, _>>()?;
                Ok(Processor::Ignore(BlockSet::from_blocks(blocks)))
            };
            // `SinglePoolElement.getSettings`: structure blocks ignored,
            // jigsaw blocks replaced, then the element's and the projection's
            // processors; a legacy element ignores air too, last.
            let mut list = Vec::new();
            if !legacy {
                list.push(ignore(&["structure_block"])?);
            }
            list.push(Processor::JigsawReplacement);
            list.extend(templates.processor_list(processors, table)?);
            if *projection == Projection::TerrainMatching {
                list.push(Processor::Gravity {
                    heightmap: Heightmap::WorldSurfaceWg,
                    offset: -1,
                });
            }
            if *legacy {
                list.push(ignore(&["structure_block", "air"])?);
            }
            let mut settings = PlaceSettings::piece(Mirror::None, rotation, [0, 0, 0], list);
            let k = c.chunk_box;
            settings.bounding_box = Some(TemplateBox {
                min: [k.min_x, k.min_y, k.min_z],
                max: [k.max_x, k.max_y, k.max_z],
            });
            settings.known_shape = true;
            settings.finalize_entities = true;
            settings.waterlogging = waterlogging;
            let d = c.placer.decoration;
            templates.place(
                d,
                c.region,
                &template,
                position,
                c.reference,
                &settings,
                c.random,
                18,
            )
        }
    }
}
