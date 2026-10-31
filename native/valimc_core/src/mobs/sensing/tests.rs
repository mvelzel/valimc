//! Sensing over small scenes (the vanilla stages check it over real
//! terrain).

use super::*;
use crate::mobs::facts::tests::fixture;
use crate::mobs::level::tests::{physics, scene, STONE};
use crate::mobs::level::Unknown;
use crate::mobs::random::LegacyRandom;
use crate::physics::source::States;

const ZOMBIE: u16 = 1;
const COW: u16 = 0;

struct Me {
    uuid: Uuid,
    type_id: u16,
    position: [f64; 3],
    sight: SightCache,
    never: Option<Uuid>,
}

impl Seer<()> for Me {
    fn uuid(&self) -> Uuid {
        self.uuid
    }
    fn type_id(&self) -> u16 {
        self.type_id
    }
    fn position(&self) -> [f64; 3] {
        self.position
    }
    fn eye_y(&self) -> f64 {
        self.position[1] + 1.74
    }
    fn sight(&mut self) -> &mut SightCache {
        &mut self.sight
    }
    fn can_attack_hook(&self, target: Entity<'_, ()>) -> bool {
        Some(target.uuid()) != self.never
    }
}

fn uuid(n: u8) -> Uuid {
    let mut u = [0; 16];
    u[15] = n;
    u
}

fn me(at: [f64; 3]) -> Me {
    Me {
        uuid: uuid(0),
        type_id: ZOMBIE,
        position: at,
        sight: SightCache::default(),
        never: None,
    }
}

fn player(n: u8, at: [f64; 3]) -> SensedPlayer {
    SensedPlayer {
        uuid: uuid(n),
        id: n as i32,
        position: at,
        yaw: 0.0,
        pitch: 0.0,
        eye: 1.62,
        width: 0.6,
        height: 1.8,
        mode: GameMode::Survival,
        invulnerable: false,
        alive: true,
        crouching: false,
        swimming: false,
        invisible: false,
        armor_cover: 0.0,
        equipment: [None; 6],
        movement: [0.0; 3],
        velocity: [0.0; 3],
        health: 20.0,
        effects: vec![],
    }
}

fn mob(n: u8, type_id: u16, at: [f64; 3]) -> SensedMob {
    SensedMob {
        uuid: uuid(n),
        id: n as i32,
        type_id,
        position: at,
        yaw: 0.0,
        pitch: 0.0,
        eye: 1.3,
        width: 0.9,
        height: 1.4,
        own_box: None,
        alive: true,
        recent_mob_hurt: false,
        baby: false,
        huntable: true,
        target: None,
        in_love: 0,
        age: 0,
        in_water: false,
        invulnerable: false,
        killed_by: None,
        panicking: false,
        invisible: false,
        armor_cover: 0.0,
        extra: (),
    }
}

#[test]
fn conditions_test_as_vanilla_does() {
    let facts = fixture();
    let (physics, states) = physics();
    let blocks = scene();
    let mut level = Level::new(
        &blocks,
        &Unknown,
        &facts,
        &physics,
        &states,
        LegacyRandom::new(1),
    );
    let mut seer = me([0.5, 64.0, -1.5]);
    let near = player(1, [0.5, 64.0, 1.5]);
    let mut creative = player(2, [0.5, 64.0, 0.5]);
    creative.mode = GameMode::Creative;
    creative.invulnerable = true;
    let mut spectator = player(3, [0.5, 64.0, 0.5]);
    spectator.mode = GameMode::Spectator;
    let combat = Conditions::new(true);
    let mut ranged = Conditions::new(true);
    ranged.range = 3.5;
    ranged.sight = false;
    assert!(test(&level, &mut seer, Entity::Player(&near), &ranged));
    assert!(!test(&level, &mut seer, Entity::Player(&creative), &combat));
    let mut peaceful = Conditions::<(), Me>::new(false);
    peaceful.sight = false;
    assert!(test(
        &level,
        &mut seer,
        Entity::Player(&creative),
        &peaceful
    ));
    assert!(!test(
        &level,
        &mut seer,
        Entity::Player(&spectator),
        &peaceful
    ));
    // Out of range at 3 blocks; crouching shrinks the range further.
    ranged.range = 2.9;
    assert!(test(&level, &mut seer, Entity::Player(&near), &ranged) == (9.0 <= 2.9 * 2.9));
    ranged.range = 4.0;
    let mut crouching = near.clone();
    crouching.crouching = true;
    assert!(test(&level, &mut seer, Entity::Player(&crouching), &ranged));
    ranged.range = 3.7;
    assert!(!test(
        &level,
        &mut seer,
        Entity::Player(&crouching),
        &ranged
    ));
    ranged.invisible = false;
    assert!(test(&level, &mut seer, Entity::Player(&crouching), &ranged));
    // Itself, the family's rule, peaceful players, a selector.
    let myself = mob(0, ZOMBIE, seer.position);
    assert!(!test(&level, &mut seer, Entity::Mob(&myself), &peaceful));
    seer.never = Some(uuid(1));
    assert!(!test(&level, &mut seer, Entity::Player(&near), &ranged));
    seer.never = None;
    level.difficulty = Difficulty::Peaceful;
    assert!(!test(&level, &mut seer, Entity::Player(&near), &ranged));
    assert!(test(
        &level,
        &mut seer,
        Entity::Mob(&mob(4, COW, [0.5, 64.0, 0.5])),
        &ranged
    ));
    let only_cows = |t: Entity<'_, ()>, _: &Me| t.type_id() == Some(COW);
    ranged.select = Some(&only_cows);
    assert!(!test(
        &level,
        &mut seer,
        Entity::Mob(&mob(5, ZOMBIE, [0.5, 64.0, 0.5])),
        &ranged
    ));
}

#[test]
fn visibility_of_players() {
    let facts = fixture();
    let (physics, states) = physics();
    let blocks = scene();
    let level = Level::new(
        &blocks,
        &Unknown,
        &facts,
        &physics,
        &states,
        LegacyRandom::new(1),
    );
    let mut p = player(1, [0.0; 3]);
    assert_eq!(visibility(&level, Entity::<()>::Player(&p), ZOMBIE), 1.0);
    p.crouching = true;
    p.invisible = true;
    p.armor_cover = 0.25;
    assert_eq!(
        visibility(&level, Entity::<()>::Player(&p), ZOMBIE),
        0.8 * 0.7 * 0.25
    );
    p.armor_cover = 0.0;
    assert_eq!(
        visibility(&level, Entity::<()>::Player(&p), ZOMBIE),
        0.8 * 0.7 * (0.1f32 as f64)
    );
    // A zombie head hides its wearer from zombies only, and only on the head.
    let mut q = player(2, [0.0; 3]);
    q.equipment[2] = Some(1);
    assert_eq!(visibility(&level, Entity::<()>::Player(&q), ZOMBIE), 0.5);
    assert_eq!(visibility(&level, Entity::<()>::Player(&q), COW), 1.0);
    q.equipment = [None, None, None, None, Some(1), None];
    assert_eq!(visibility(&level, Entity::<()>::Player(&q), ZOMBIE), 1.0);
    assert_eq!(
        visibility(&level, Entity::Mob(&mob(3, COW, [0.0; 3])), ZOMBIE),
        1.0
    );
}

#[test]
fn sight_is_cast_through_collision_shapes_and_cached() {
    let facts = fixture();
    let (physics, states) = physics();
    let mut blocks = scene();
    // A stone wall between two points; scaffolding-like states are not here.
    blocks.0.insert([0, 65, 0], STONE);
    blocks.0.insert([0, 66, 0], STONE);
    let level = Level::new(
        &blocks,
        &Unknown,
        &facts,
        &physics,
        &states,
        LegacyRandom::new(1),
    );
    let mut seer = me([0.5, 64.0, -1.5]);
    let behind = player(1, [0.5, 64.0, 1.5]);
    let beside = player(2, [1.5, 64.0, -1.5]);
    assert!(!line_of_sight(&level, &seer, Entity::<()>::Player(&behind)));
    assert!(line_of_sight(&level, &seer, Entity::<()>::Player(&beside)));
    // Unreadable cells read as air.
    let far = player(3, [0.5, 64.0, -40.5]);
    assert!(line_of_sight(&level, &seer, Entity::<()>::Player(&far)));
    let too_far = player(4, [0.5, 64.0, 140.0]);
    assert!(!line_of_sight(
        &level,
        &seer,
        Entity::<()>::Player(&too_far)
    ));
    assert!(!sees(&level, &mut seer, Entity::<()>::Player(&behind)));
    // The cache answers until cleared, even when the world changes.
    let open = scene();
    let level = Level::new(
        &open,
        &Unknown,
        &facts,
        &physics,
        &states,
        LegacyRandom::new(1),
    );
    assert!(!sees(&level, &mut seer, Entity::<()>::Player(&behind)));
    seer.sight.clear();
    assert!(sees(&level, &mut seer, Entity::<()>::Player(&behind)));
    let _ = States(HashMap::new());
}

#[test]
fn nearest_takes_the_first_closest_that_passes() {
    let facts = fixture();
    let (physics, states) = physics();
    let blocks = scene();
    let level = Level::new(
        &blocks,
        &Unknown,
        &facts,
        &physics,
        &states,
        LegacyRandom::new(1),
    );
    let players = vec![
        player(1, [2.5, 64.0, 0.5]),
        player(2, [-1.5, 64.0, 0.5]),
        player(3, [0.5, 64.0, 2.5]),
    ];
    let sensing: Sensing = Sensing::new(players, vec![], vec![]);
    let mut seer = me([0.5, 64.0, 0.5]);
    let mut c = Conditions::new(false);
    c.sight = false;
    let found = nearest_player(&level, &sensing, &mut seer, &c, [0.5, 64.0, 0.5]).unwrap();
    assert_eq!(found.id, 1);
    let found = nearest_player(&level, &sensing, &mut seer, &c, [0.5, 64.0, 3.0]).unwrap();
    assert_eq!(found.id, 3);
}

#[test]
fn grid_queries_equal_linear_ones_after_resensing() {
    let facts = fixture();
    let (physics, states) = physics();
    let blocks = scene();
    let level = Level::new(
        &blocks,
        &Unknown,
        &facts,
        &physics,
        &states,
        LegacyRandom::new(1),
    );
    let mobs: Vec<SensedMob> = (1..=160u8)
        .map(|n| {
            let mut m = mob(
                n,
                if n % 3 == 0 { COW } else { ZOMBIE },
                [
                    (n % 16) as f64 * 8.0 - 64.0,
                    (n % 2) as f64 * 10.0 + 64.0,
                    (n / 16) as f64 * 8.0 - 40.0,
                ],
            );
            if n == 1 {
                m.width = 32.0;
            }
            m
        })
        .collect();
    let mut indexed = Sensing::new(vec![], vec![], mobs.clone());
    let mut linear = Sensing::new(vec![], vec![], mobs.clone());
    linear.grid = None;
    assert!(indexed.grid.is_some());
    let only_cows = |t: u16| t == COW;
    for m in &mobs {
        for s in [&mut indexed, &mut linear] {
            s.resense(&m.uuid, |m| {
                m.position[0] += 31.0;
                m.position[2] -= 17.0;
                m.alive = false;
            });
        }
        let b = inflate(&m.bounding_box(), 8.0, 5.0, 8.0);
        let wide = Aabb::new([-1000.0; 3], [1000.0; 3]);
        for b in [b, wide] {
            for select in [
                Select::Types(&[COW]),
                Select::Types(&[COW, ZOMBIE]),
                Select::Types(&[]),
                Select::Any,
                Select::Where(&only_cows),
            ] {
                assert_eq!(indexed.mobs_in(&select, &b), linear.mobs_in(&select, &b));
            }
        }
    }
    // Section order and the nearest mob over a query.
    let all = indexed.mobs_in(&Select::Any, &Aabb::new([-1000.0; 3], [1000.0; 3]));
    assert_eq!(all, (0..160).collect::<Vec<_>>());
    let mut seer = me([0.0, 64.0, 0.0]);
    let mut c = Conditions::new(false);
    c.sight = false;
    let alive: Sensing = Sensing::new(vec![], vec![], mobs);
    let near = nearest_mob(
        &level,
        &alive,
        &mut seer,
        &Select::Types(&[COW]),
        &Aabb::new([-20.0, 50.0, -20.0], [20.0, 80.0, 20.0]),
        &c,
        [0.0, 64.0, 0.0],
    )
    .unwrap();
    assert_eq!(near.type_id, COW);
    assert!(near.position[0].abs() <= 8.0 && near.position[2].abs() <= 8.0);
    assert!(alive
        .entity(&Ref {
            kind: Kind::Mob,
            uuid: near.uuid
        })
        .is_some());
    assert!(!indexed.resense(&uuid(200), |_| {}));
}
