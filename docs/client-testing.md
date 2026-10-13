# Minecraft Java 26.3 client testing

Date: October 13, 2026. Local address: `localhost:25565`.

The running graphical client's `logs/latest.log` recorded a connection at 17:31:51 and a `Network Protocol Error` during configuration. The cause was missing vanilla registry tags, including `minecraft:infiniburn_overworld`, enchantment item tags, and sulfur-cube archetype tags. ValiMC had sent an empty `update_tags` packet.

The server now sends 773 resolved vanilla tags across 15 registries. The payload is encoded once at application startup and shared as an immutable binary between connections. Static registry IDs come from Mojang's built-in registries; synchronized dynamic registry IDs match ValiMC's alphabetically ordered entries.

The previous oracle validated packet syntax using prebuilt vanilla registries. It could therefore pass while the graphical client's registry dependency loading failed. The oracle now loads the actual received entries and tags through Mojang's `RegistryDataLoader` with the vanilla data pack. This strengthened test failed against the old running server and passed against the fixed server, including all 32 synchronized registries, 49 chunks, two players, movement, ordinary creative block placement/breaking, and commands. All 17 ExUnit tests also passed.

Graphical verification of rendering and interactions remains pending. The computer-use app inventory recognizes the Minecraft Launcher, but rejects the standalone running Java game by name, bundle identifier, runtime bundle path, and executable path. The user was asked to reconnect after the fixed server restarted at 17:41:12. The test server uses a separate temporary world at `/tmp/valimc-client-test-world`.
