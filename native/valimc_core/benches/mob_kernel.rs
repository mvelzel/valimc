//! The mob kernel's cost per mob (VMC-081d): randomized owner scenes
//! (`tests/support/mob_scenes.rs`) of grounded walkers, idle animals, crowds
//! in pens, walkers over slabs, stairs and fences, swimmers, fliers,
//! climbers, hoppers, striders and fixed mobs, with items, timed per kernel
//! step after a warm-up. Run with
//! `cargo bench -p valimc_core --bench mob_kernel [-- SCENES TICKS]`.

#[path = "../tests/support/mob_scenes.rs"]
mod mob_scenes;

use mob_scenes::{Kind, Scene, MIXED};
use std::collections::BTreeMap;

const CROWDED: &[(Kind, usize)] = &[(Kind::Crowd, 70), (Kind::Walker, 10), (Kind::Idle, 10)];

#[derive(Default)]
struct Stat {
    ns: u64,
    calls: u64,
    faults: u64,
}

fn main() {
    let args: Vec<String> = std::env::args()
        .skip(1)
        .filter(|a| !a.starts_with("--"))
        .collect();
    let scenes: u64 = args.first().and_then(|a| a.parse().ok()).unwrap_or(6);
    let ticks: usize = args.get(1).and_then(|a| a.parse().ok()).unwrap_or(200);
    let warm = 20;
    let mut kinds: BTreeMap<Kind, Stat> = BTreeMap::new();
    let mut items = Stat::default();
    let mut faults: BTreeMap<String, u64> = BTreeMap::new();
    let wall = std::time::Instant::now();
    for seed in 0..scenes {
        let mix = if seed % 3 == 2 { CROWDED } else { MIXED };
        let mut scene = Scene::new(100 + seed, mix, 60);
        for t in 0..ticks + warm {
            let counted = t >= warm;
            scene.tick(
                &mut |kind, result, _, ns| {
                    if counted {
                        let s = kinds.entry(kind).or_default();
                        s.ns += ns;
                        s.calls += 1;
                        if let Err(f) = result {
                            s.faults += 1;
                            *faults.entry(format!("{kind:?} {f:?}")).or_default() += 1;
                        }
                    }
                },
                &mut |result, ns| {
                    if counted {
                        items.ns += ns;
                        items.calls += 1;
                        items.faults += u64::from(result.is_err());
                    }
                },
            );
        }
    }
    let (ns, calls) = kinds
        .values()
        .fold((0, 0), |(n, c), s| (n + s.ns, c + s.calls));
    println!(
        "{scenes} scenes x {ticks} ticks in {:.1} s",
        wall.elapsed().as_secs_f64()
    );
    println!(
        "{:<10} {:>9} {:>9} {:>8}",
        "kind", "steps", "us/step", "faults"
    );
    for (kind, s) in &kinds {
        println!(
            "{:<10} {:>9} {:>9.3} {:>8}",
            format!("{kind:?}"),
            s.calls,
            s.ns as f64 / s.calls as f64 / 1e3,
            s.faults
        );
    }
    println!(
        "{:<10} {:>9} {:>9.3}",
        "all mobs",
        calls,
        ns as f64 / calls as f64 / 1e3
    );
    println!(
        "{:<10} {:>9} {:>9.3} {:>8}",
        "items",
        items.calls,
        items.ns as f64 / items.calls as f64 / 1e3,
        items.faults
    );
    for (f, n) in faults {
        println!("fault {f}: {n}");
    }
}
