# Architecture

## Layering

```
ReplicatedStorage/Shared        pure logic, no side effects, no service access
  Config            tunables, versions, recipes, materials (NO Roblox datatypes)
  Hash              deterministic hashing + PRNG streams (bit32 + 16-bit limb mul)
  Address           G1-S00001234-P03 parse/format
  StarLattice       bijection system index <-> 3D lattice cell, neighbours
  GalaxyGen         star/planet descriptors, biomes, descriptions
  TerrainGen        height field, deposit + landmark layout, chunk bounds
  ShipModules       module whitelist + derived stat model + build costs
  Blueprint         blueprint validation/serialisation (server-authoritative)
  ShipStates        state machine + legal transitions
  GameConfig        Roblox-facing helpers (Color3, Vector3, Terrain materials)

ReplicatedStorage/Remotes       created by the server at boot (single source)
ServerScriptService/Services    one concern per module, all server-owned
ServerScriptService/Listeners   thin remote wiring -> services
ServerStorage/Templates         trusted server-only templates
StarterPlayerScripts/Controllers client input, camera, HUD, chart, workshop
```

## Determinism

Everything procedural is a pure function of
`(Config.GENERATION_VERSION, galaxy id, system id, planet slot, stream salt)`.
`Config.GENERATION_VERSION` is mixed into every hash. Bumping it permutes the
entire galaxy; it must only be bumped deliberately.

`math.random` is never used for world generation. `Hash.stream(seed)` provides
splitmix32-based streams.

## Scale

- 10,000,000 system addresses (`G1-S00000000` … `G1-S09999999`)
- 10 planet slots per system → **100,000,000** planet addresses
- Systems are placed on a 216³ lattice (10,077,696 cells) via a modular
  bijection, so "nearby systems" is a bounded 3D neighbourhood query and the
  galaxy is genuinely spatial. No 100M-entry table exists anywhere.

## Streaming

Only the active destination is ever materialised:
- planet terrain is written in 48-stud chunks with a 5×5 loaded radius and
  hysteresis unload, budgeted per frame (`Config.PLANET.FILLS_PER_FRAME`),
- deposits and landmarks exist only for the loaded area,
- space is a single bounded sandbox zone; other systems are chart data only.
