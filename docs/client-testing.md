# Minecraft Java 26.3 client testing

Date: October 13, 2026. Local address: `localhost:25565`.

The running graphical client's `logs/latest.log` recorded a connection at 17:31:51 and a `Network Protocol Error` during configuration. The cause was missing vanilla registry tags, including `minecraft:infiniburn_overworld`, enchantment item tags, and sulfur-cube archetype tags. ValiMC had sent an empty `update_tags` packet.

The server now sends 773 resolved vanilla tags across 15 registries. The payload is encoded once at application startup and shared as an immutable binary between connections. Static registry IDs come from Mojang's built-in registries; synchronized dynamic registry IDs match ValiMC's alphabetically ordered entries.

The previous oracle validated packet syntax using prebuilt vanilla registries. It could therefore pass while the graphical client's registry dependency loading failed. The oracle now loads the actual received entries and tags through Mojang's `RegistryDataLoader` with the vanilla data pack. This strengthened test failed against the old running server and passed against the fixed server, including all 32 synchronized registries, 49 chunks, two players, movement, ordinary creative block placement/breaking, and commands. All 17 ExUnit tests also passed.

The user confirmed that the flat world rendered after the fix. Computer use initially rejected the unbundled Java process. A local macOS app launcher using the existing official Java runtime made the game discoverable as `local.valimc.minecraft-client`. The separate Launcher installation is **ValiMC computer-use test**. Screenshot capture, mouse navigation through Multiplayer, localhost join/rendering, and keyboard `/stats` execution were then observed through computer use. The displayed response included one player, eight regions, ten schedulers and 63 MiB. This confirms these specific GUI scenarios; it does not establish all creative or survival mechanics. The test server uses `/tmp/valimc-client-test-world`.

The repeatable setup and verification process are documented in `development.md`. Ticket records below will add fresh evidence for each checkpoint; private captures belong under `.local/client-tests/`.
