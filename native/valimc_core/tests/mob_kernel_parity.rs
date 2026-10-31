//! The mob and item kernels give bit-identical results across their
//! optimisations (VMC-081d): randomized scenes run for a stretch of ticks and
//! everything the kernels return (positions, velocities, flags, contacts,
//! faults, pushes) is digested exactly (`{:?}` prints every float's shortest
//! round trip, the sign of zero included). The expected digests are the
//! kernel's before its optimisation; a change in any scene's behaviour shows
//! as that scene's digest. `MOB_PARITY_PRINT=1` prints the digests.

mod support;

use support::mob_scenes::{Digest, Kind, Scene, MIXED};

/// A crowd-heavy owner: two pens packed with animals among walkers.
const CROWDED: &[(Kind, usize)] = &[(Kind::Crowd, 70), (Kind::Walker, 10), (Kind::Idle, 10)];

const TICKS: usize = 60;

/// `(seed, mix, items)` and the digests of mobs and items.
const EXPECTED: &[(u64, bool, u64, u64)] = &[
    (1, false, 0x5745af3456616a3f, 0x60445ab62af69695),
    (2, false, 0x04f3714d88d2f346, 0x4a66fe7f0022254d),
    (3, false, 0x5ab9b527a2234c38, 0x3ef2f9fcf7d53fc4),
    (4, false, 0x8f89819cc238e4a6, 0x47ed4b72eeedba48),
    (5, true, 0x718b42eaa90db478, 0xb944d417bee5b62d),
    (6, true, 0x8af28603cb2ad230, 0x40bf858d9fc18dc5),
];

fn run(seed: u64, crowded: bool) -> (u64, u64) {
    let mix = if crowded { CROWDED } else { MIXED };
    let mut scene = Scene::new(seed, mix, 40);
    let mut mobs = Digest::new();
    let mut items = Digest::new();
    // `MOB_PARITY_TRACE=PREFIX` writes every line digested, to compare runs.
    let mut trace = std::env::var("MOB_PARITY_TRACE").ok().map(|prefix| {
        std::io::BufWriter::new(std::fs::File::create(format!("{prefix}-{seed}")).unwrap())
    });
    let mut write = |line: &str| {
        if let Some(t) = trace.as_mut() {
            std::io::Write::write_all(t, line.as_bytes()).unwrap();
        }
    };
    let ticks = std::env::var("MOB_PARITY_TICKS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(TICKS);
    for _ in 0..ticks {
        let mut lines = Vec::new();
        let mut item_lines = Vec::new();
        scene.tick(
            &mut |kind, result, pushed, _| {
                let line = format!("{kind:?} {result:?} {pushed:?}\n");
                mobs.add(&line);
                lines.push(line);
            },
            &mut |result, _| {
                let line = format!("{result:?}\n");
                items.add(&line);
                item_lines.push(line);
            },
        );
        lines.append(&mut item_lines);
        for m in &scene.mobs {
            let line = format!("{:?}\n", m.velocity);
            mobs.add(&line);
            lines.push(line);
        }
        lines.iter().for_each(|l| write(l));
    }
    (mobs.0, items.0)
}

#[test]
fn mob_and_item_kernels_match_their_recorded_results() {
    let cases: &[(u64, bool)] = &[
        (1, false),
        (2, false),
        (3, false),
        (4, false),
        (5, true),
        (6, true),
    ];
    let print = std::env::var("MOB_PARITY_PRINT").is_ok();
    let mut failures = Vec::new();
    for &(seed, crowded) in cases {
        let (mobs, items) = run(seed, crowded);
        if print {
            println!("    ({seed}, {crowded}, 0x{mobs:016x}, 0x{items:016x}),");
        }
        match EXPECTED.iter().find(|e| e.0 == seed && e.1 == crowded) {
            Some(&(_, _, m, i)) if m == mobs && i == items => {}
            _ => failures.push((seed, crowded, mobs, items)),
        }
    }
    assert!(failures.is_empty(), "digests differ: {failures:x?}");
}

/// More scenes, to compare two builds' printed digests
/// (`MOB_PARITY_SEEDS`, `MOB_PARITY_TICKS`; `--ignored --nocapture`).
#[test]
#[ignore]
fn print_extended_digests() {
    let seeds: u64 = std::env::var("MOB_PARITY_SEEDS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(40);
    for seed in 1000..1000 + seeds {
        let (mobs, items) = run(seed, seed % 4 == 0);
        println!("{seed} 0x{mobs:016x} 0x{items:016x}");
    }
}
