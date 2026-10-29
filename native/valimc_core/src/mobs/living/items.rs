//! Reading and writing `%ItemStack{}` terms (`Valimc.Protocol.ItemStack`)
//! as the living rules do: the item id, its components (by name), the
//! components it removes (a `MapSet`) and its enchantment levels.

use super::super::term::{Map, Value};

/// `stack.item_id`.
pub fn item_id(stack: &Value) -> Option<i32> {
    stack
        .as_map()?
        .get_atom("item_id")?
        .as_int()
        .and_then(|i| i32::try_from(i).ok())
}

fn components(stack: &Value) -> Option<&Map> {
    stack.as_map()?.get_atom("components")?.as_map()
}

/// `Map.get(stack.components, name)`.
pub fn component<'a>(stack: &'a Value, name: &str) -> Option<&'a Value> {
    components(stack)?.get(&Value::Binary(name.as_bytes().to_vec()))
}

/// `MapSet.member?(stack.removed, name)`.
pub fn removed(stack: &Value, name: &str) -> bool {
    let Some(set) = stack.as_map().and_then(|m| m.get_atom("removed")) else {
        return false;
    };
    // `%MapSet{map: %{name => []}}`.
    set.as_map()
        .and_then(|m| m.get_atom("map"))
        .and_then(Value::as_map)
        .is_some_and(|m| m.get(&Value::Binary(name.as_bytes().to_vec())).is_some())
}

/// The component as `component/3` reads it: nil when removed, else the
/// stack's or `default`.
pub fn component_or<'a>(
    stack: &'a Value,
    name: &str,
    default: Option<&'a Value>,
) -> Option<&'a Value> {
    if removed(stack, name) {
        None
    } else {
        component(stack, name).or(default)
    }
}

/// The stack's enchantment levels by name, in map order
/// (`Map.get(components, "minecraft:enchantments", %{})`).
pub fn enchantments(stack: &Value) -> Vec<(&str, i64)> {
    let Some(map) = component(stack, "minecraft:enchantments").and_then(Value::as_map) else {
        return Vec::new();
    };
    map.iter()
        .filter_map(|(k, v)| Some((std::str::from_utf8(k.as_binary()?).ok()?, v.as_int()?)))
        .collect()
}

/// One enchantment's level on the stack (0 without it).
pub fn enchantment(stack: &Value, name: &str) -> Option<i64> {
    component(stack, "minecraft:enchantments")?
        .as_map()?
        .get(&Value::Binary(name.as_bytes().to_vec()))?
        .as_int()
}

/// `Map.put(stack.components, name, value)`.
pub fn put_component(stack: &mut Value, name: &str, value: Value) {
    let Value::Map(map) = stack else {
        return;
    };
    let mut components = match map.get_atom("components") {
        Some(Value::Map(c)) => c.clone(),
        _ => Map::new(),
    };
    components.insert(Value::Binary(name.as_bytes().to_vec()), value);
    map.insert_atom("components", Value::Map(components));
}
