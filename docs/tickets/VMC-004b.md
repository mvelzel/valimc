# VMC-004b — Recursive and collection item components

Status: Awaiting client
Milestone: M4
Lane: Containers (then [VMC-032c](VMC-032c.md)).
Done before M4: [004b1](VMC-004b1.md) (bounded network NBT, custom data),
[004b2a](VMC-004b2a.md)–[004b2e](VMC-004b2e.md) (effective identity, names and
lore, enchantments, tooltip display) and [004b3](VMC-004b3.md) (item hovers).

At M4's start a stack holds 34 of 26.3's 122 component types. A stack with any
other component is refused, so shulker boxes cannot carry contents, a bundle
cannot fill, and gear with modified attributes cannot exist. This ticket gives
every component type a codec in both of vanilla's formats, the network stream
and the data (NBT) form that world files, commands and item hovers use.

Acceptance (the backlog row):

- Every 26.3 component type decodes and encodes in both formats, and a stack
  holding any of them keeps it through menus, drops, storage and hovers.
- Decoding is bounded: nesting depth, list sizes and bytes have explicit
  limits, checked before allocation; a bad component rejects only its session.
- Oracle round trips: Mojang encodes every item prototype's components and
  constructed values for the rest; ValiMC decodes and re-encodes them, and
  Mojang decodes ValiMC's bytes back to equal values.
- A destroyed item that holds items (a shulker box, a bundle) drops them.

Slices, in order:

| Slice | Scope |
|---|---|
| [004b4](VMC-004b4.md) | The component schema engine, generated registries and enums, every flat component |
| [004b5](VMC-004b5.md) | Attribute modifiers and the gameplay records (consumable, equippable, tool, weapons, predicates) |
| [004b6](VMC-004b6.md) | Item-holding components: container, bundle, use remainder, sulfur cube, templates |
| [004b7](VMC-004b7.md) | Entity, block-entity, profile, book and sign data; persistent-only components |
| [004b8](VMC-004b8.md) | A destroyed item drops its contents |
| [004b9](VMC-004b9.md) | Bundle interactions: putting items in, taking them out, selection |

The codecs feed the other M4 lanes (enchantable and repairable for
enchanting, consumable and potion duration scale for brewing, additional
trade cost for trading), so each slice lands on `main` as soon as it passes.

## Status (October 31, 2026)

The backlog row's gate is met: 004b4–004b8 are on `main`. All 122 component
types round-trip both formats against Mojang (`item_components`), decoding is
bounded, and a destroyed shulker box or bundle spills its contents.
`mix test.fast` passes (720 of 721 on the first run; the one failure was a
test that still expected a writable book to be unholdable, now fixed).

Awaiting client, in M4's batch: 004b8's lava and creeper scenarios, and
creative items that now carry components (an ominous banner, fireworks of
each flight duration, a painting variant, a named shulker box from the
creative menu keeping its tooltip). Bundle interactions ([004b9](VMC-004b9.md))
are not part of the gate; they stay planned in this lane.
