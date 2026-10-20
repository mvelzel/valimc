//! Operation traces over random sources, for parity checks against vanilla
//! (`RandomOracle` runs the same operations on vanilla's classes).
//!
//! Operations: `int`, `bounded:N`, `long`, `bool`, `float`, `double`,
//! `gaussian`, `consume:N`, `fork` (continue on the fork), `at:X,Y,Z`,
//! `hash:TEXT` and `seed:N` (continue on that random of a positional factory
//! forked from the current source). Floats and doubles are their raw bits.

use super::random::Random;

pub fn run(kind: &str, seed: i64, ops: &[String]) -> Result<Vec<String>, String> {
    let mut random = match kind {
        "xoroshiro" => Random::xoroshiro(seed),
        "legacy" => Random::legacy(seed),
        other => return Err(format!("unknown kind {other}")),
    };
    let mut out = Vec::with_capacity(ops.len());
    for op in ops {
        let (name, arg) = op.split_once(':').unwrap_or((op.as_str(), ""));
        let number = |text: &str| {
            text.parse::<i64>()
                .map_err(|_| format!("bad argument in {op}"))
        };
        let value = match name {
            "int" => random.next_int().to_string(),
            "bounded" => random.next_int_bounded(number(arg)? as i32).to_string(),
            "long" => random.next_long().to_string(),
            "bool" => random.next_bool().to_string(),
            "float" => format!("{:08x}", random.next_float().to_bits()),
            "double" => format!("{:016x}", random.next_double().to_bits()),
            "gaussian" => format!("{:016x}", random.next_gaussian().to_bits()),
            "consume" => {
                random.consume_count(number(arg)? as i32);
                "-".to_string()
            }
            "fork" => {
                random = random.fork();
                "-".to_string()
            }
            "at" => {
                let parts: Vec<i32> = arg.split(',').map(|p| p.parse().unwrap_or(0)).collect();
                random = random.fork_positional().at(parts[0], parts[1], parts[2]);
                "-".to_string()
            }
            "hash" => {
                random = random.fork_positional().from_hash_of(arg);
                "-".to_string()
            }
            "seed" => {
                random = random.fork_positional().from_seed(number(arg)?);
                "-".to_string()
            }
            other => return Err(format!("unknown operation {other}")),
        };
        out.push(value);
    }
    Ok(out)
}
