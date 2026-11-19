# Deep Field

An original multiplayer space-exploration sandbox for Roblox. You get a ship, a
galaxy with 100,000,000 addressable planets, and a scanner. Pick a destination,
fly there, land, walk out, mine, rebuild your ship in the workshop, and go again.
There is no quest line, no story, no levels and no dialogue — the game is the
sandbox and the things you decide to do in it.

Everything in this repository is implemented source: 47 Luau modules, one server
Script, one client Script, plus an offline test harness that executes the real
modules (148 assertions currently passing).

---

## Quick start

### Option A — Rojo (one command)

```bash
npm install            # only needed for the test harness, not the game
rojo serve             # then: Studio → Plugins → Rojo → Connect
```

`default.project.json` maps `src/` onto the right services, so a single sync
produces the finished Explorer layout (see below). No manual reparenting.

### Option B — manual placement in Studio

Create a place, delete the default `Baseplate` and `SpawnLocation` (the game
clears them itself at boot if you forget), then mirror this layout:

```
ReplicatedStorage
└── Shared                      ← Folder  ("src/ReplicatedStorage/Shared" as ModuleScripts)
    Config, Hash, Address, StarLattice, GalaxyGen, TerrainGen,
    ShipModules, Blueprint, ShipStates, ShipPermissions, GameConfig

ServerScriptService
├── Bootstrap                   ← Script  (src/ServerScriptService/Bootstrap.server.lua)
└── Services                    ← Folder  (ModuleScripts)
    RemoteService, Templates, DataSchema, PlayerDataService, InventoryService,
    ShipBuilder, ShipService, PlanetService, FlightService, MiningService,
    DiscoveryService, CraftingService, BlueprintService, UniverseService,
    ActionRouter

ServerStorage
└── Templates                   ← Folder (empty; prototypes are built at boot)

StarterPlayer
└── StarterPlayerScripts
    ├── ClientMain              ← LocalScript (src/.../ClientMain.client.lua)
    ├── Controllers             ← Folder  (ModuleScripts)
    │   NetController, ClientState, InputController, CameraController,
    │   FlightController, WorkshopController, MiningController
    └── UI                      ← Folder  (ModuleScripts)
        Theme, UIKit, HUD, Modal, ChartPanel, InventoryPanel, WorkshopPanel,
        CatalogPanel, ScannerPanel, ShipPanel, SettingsPanel, TouchControls
```

Rules that matter when placing files:

* **`Bootstrap` must be a `Script`** (server), **`ClientMain` must be a
  `LocalScript`**. Everything else is a `ModuleScript`.
* The folder names are part of the require paths (`script.Parent.Services`,
  `ReplicatedStorage.Shared`). Renaming a folder breaks the build.
* Nothing else goes in `Workspace` — terrain, deposits, landmarks and the ship
  are all generated at runtime.
* Game settings → **Workspace → StreamingEnabled = true** (the bootstrap turns
  it on too) and **Lighting → Technology = Future**.

Press **Play**. You spawn on the landing pad of `G1-S00001234-P03` next to your
starter ship, the *Wayfarer*.

---

## The loop

```
chart a destination → warp → orbit → descend → land
      ↑                                          ↓
   workshop ← board ship ← mine/scan ← walk out of the hatch
```

1. **Choose a destination.** `Chart` lists nearby systems; type any address
   (e.g. `G1-S00004207-P04`) to jump the chart anywhere in the galaxy.
2. **Fly there.** Warp range is a ship stat — a bigger warp drive reaches
   further systems. Travel is a visible launch/orbit/landing transition, not a
   seamless flight from space to surface.
3. **Land, then physically leave the ship.** The hatch is a real part with a
   proximity prompt. It must be *closed* before launch.
4. **Scan and mine.** The scanner returns a server-generated planet profile plus
   the deposits within range. Mine with the prompt on each deposit.
5. **Go back in, sit at the pilot seat, launch.** Seats are physical; there is no
   teleport-to-cockpit.
6. **Rebuild.** The workshop is a 3D grid editor in front of your ship. Save
   designs to slots, then refit — only newly added modules are charged for.

Nothing is gated behind progress. The starter ship and starter kit are enough to
do everything; upgrades buy range, speed, cargo and toughness.

---

## Controls

### Desktop

| Action | Key |
| --- | --- |
| Walk / look | `WASD` + mouse |
| Take the pilot seat / use the hatch | `E` (context sensitive, or click the prompt) |
| Stand up from the pilot seat | `E` again, or `X` |
| Interact prompt | `E` or click |
| Throttle / reverse | `W` / `S` |
| Strafe left / right | `A` / `D` |
| Yaw left / right | `←` / `→` |
| Pitch up / down | `↑` / `↓` |
| Climb / descend | `Space` / `Left Ctrl` |
| Brake | `F` |
| Launch | `L` |
| Land / descend to surface | `K` |
| Landing gear | `G` |
| Scan | `R` |
| Chart | `Tab` (also `M`) |
| Catalogue of discoveries | `C` |
| Cargo / inventory | `I` |
| Workshop | `B` |
| Close panel | `Esc` |

### Gamepad

| Action | Button |
| --- | --- |
| Throttle / strafe | Left thumbstick |
| Yaw / pitch | Right thumbstick |
| Climb / descend | `R2` / `L2` |
| Brake | `X` (held) — this is the same button, so on foot it stands you up |
| Interact (seat, hatch, prompt) | `Y` |
| Stand up from the pilot seat | `X`, or `Y` (Interact is context sensitive: seated = stand) |
| Scan | `R1` |
| Chart | `L1` |
| Launch | D-pad up |
| Land | D-pad down |
| Cargo | Select |

### Mobile / touch

* **Left thumb joystick** (appears while you are the pilot): up/down = throttle,
  left/right = strafe. The readout under it shows the current thrust.
* **Steering pad** (bottom right while piloting): slide your right thumb
  horizontally to yaw, vertically to pitch, and all the way down to brake. It is
  a fixed pad rather than a floating stick, so it never fights the camera.
* **Flight layer** on a touch device (joystick + `Launch`, `Land`, `Gear`,
  `Hatch`, `Scan`, `Console`, `Stand`) appears only while you are the seated
  pilot, so a phone piloting the ship never fights the walking controls.
* **Action bar** (bottom right, always visible): Scan, Chart, Workshop,
  Catalogue, Stand, Settings — all sized to the 44 px+ touch target minimum.
* You can only stand up once the ship is back on the ground; the server
  refuses to free the seat during takeoff, flight or landing.
* Deposits, the hatch and the seat all use Roblox proximity prompts, which are
  tap-friendly by default.
* Panels are single-column, scrollable, and respect the device safe area. The
  touch layer only appears when a touch device is detected.

---

## Ship workshop

The workshop opens a 3D preview rig directly in front of the ship (camera is
taken over while it is open).

* **Modules** come from a curated catalogue (hull, engines, wings/stabilisers,
  cargo, scanner, power, landing gear, optional shield/utility). A cockpit cabin
  is mandatory and is the only module that provides the walkable interior.
* **Place / remove / rotate**: tap a palette entry, tap a grid cell to place,
  tap a placed module to remove, tap again to rotate in 90° steps. Illegal cells
  are rejected locally (overlap, adjacency, module cap) and re-checked on the
  server.
* **Colours**: a fixed palette of 8 factory finishes, applied to primary /
  secondary / accent slots. No arbitrary colour input.
* **Naming**: ships are named (max 24 characters); the name appears on a
  billboard above the hull and in every panel.
* **Saved slots**: up to 4 versioned designs. `Save` stores the current board,
  `Load` opens a stored slot, `Refit` applies a slot to the live ship.
* **Costs and stats are server-side.** The preview shows the server's numbers
  (speed, handling, cargo, scanner range, warp range, power draw, mass); the
  client cannot declare them. Stats are capped in `ShipModules.STAT_CAPS`, and
  the server re-validates every design with `Blueprint.validate` before building
  anything (whitelisted ids, max part count, connectivity, one cockpit, no
  overlap).

---

## Multiplayer

The current build is a **single shared expedition per server**: one ship
(`SHIP-1`), one active planet, one destination. That is a deliberate scope
decision, not a limitation of the code — the services are already written around
an expedition object so per-crew expeditions can be added without redesign, but
this build does not claim to have them.

* Everyone in the server joins the crew. The ship's owner is `Captain`.
* Roles: `Captain` (full control, including granting pilot rights), `Pilot` (may
  take the seat, fly, warp and refit), `Crew` (hatch, scan, mine, cargo, ride
  along).
* **One pilot at a time.** The seat is a real `Seat`; sitting in it claims the
  controls, standing up releases them. Only a pilot-rated player may sit.
  Standing up is a server op (`SeatRelease`) that only the seated pilot — or the
  ship owner, to clear a stale occupant — may call, and it is refused while the
  ship is in takeoff, flight or landing.
* Permissions are enforced on the server in `ShipPermissions` — the client UI
  greys out what you cannot do, but the server refuses regardless.
* Cargo is split: **personal inventory** (per player, what mining pays into) vs
  **ship cargo** (shared, upgraded by cargo modules).
* A pilot leaving mid-flight hands control back cleanly (the server clears the
  pilot seat when the `Seat`'s Occupant empties, and refuses an explicit
  `SeatRelease` unless the ship is on the ground).

---

## Persistence

* `DataStoreService` on the server only, one versioned document per player
  (`DataStore_v<schema>` / `p_<UserId>`).
* Every call is wrapped in `pcall` with bounded exponential backoff and jitter.
* Autosave on an interval plus a save on `PlayerRemoving`. Mining a rock does
  **not** write to DataStore — gameplay mutates the in-memory document and marks
  it dirty.
* Loaded data is validated and migrated (`DataSchema.validate` / `.migrate`);
  bad fields are repaired, not trusted.
* If DataStore is unavailable, the session continues in memory, the player is
  warned once, and `persistent = false` is shown in Settings. Nothing blocks
  play.

---

## Architecture

```
src/
├── ReplicatedStorage/Shared/     pure Luau: no Instance creation, no remotes
├── ServerScriptService/          one Script + service modules (authority)
├── ServerStorage/Templates/      trusted prototype parts (built at boot)
└── StarterPlayer/StarterPlayerScripts/
    ├── Controllers/              transport, input, camera, state cache
    └── UI/                       theme, kit, panels
```

* **Shared code is deterministic and pure.** Galaxy, terrain, ship stats and the
  blueprint format live here so client and server always agree. Seeds come from a
  versioned hash (`Hash`, `GALAXY_ID`, `GENERATION_VERSION`); there is no
  unseeded `math.random` anywhere in `src/`.
* **Server owns outcomes**: distances, cooldowns, rewards, cargo, ship state,
  pilot identity, blueprint validity. The client sends intent only.
* **One route in**: every request goes through `ActionRouter` on a single
  `ClientAction` remote with an op allow-list and per-op token-bucket rate
  limits. `RemoteService` is the only place remotes are created.
* **One route out**: servers push `StateUpdate` messages by kind; the client's
  `ClientState` is the single mirror that every panel reads.
* **No god-script**: `Bootstrap.server.lua` only starts services and handles the
  spawn/streaming loop. Client `ClientMain` wires modules together.

More detail, including the streaming strategy and the 100M-planet address
scheme, is in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

### The galaxy

* 10,000,000 systems × 10 slots = **100,000,000** planet addresses.
* Addresses are human-typeable: `G1-S00001234-P03`.
* Systems are placed by a bijective lattice function (`StarLattice`), so any
  system's neighbours and distance are computable without storing a galaxy.
* Same address ⇒ same star, same biome, same heights, same deposits, forever
  (pinned by tests, including a full terrain rebuild comparison).
* The galaxy is never instantiated: the chart probes at most a few dozen
  neighbours, and only the active planet's 5×5 chunk ring exists as terrain.

### Performance

* Terrain is written in 48-stud chunks, 2-chunk view radius, 3-chunk unload
  hysteresis, and a per-frame fill budget (`FILLS_PER_FRAME`) so mobile devices
  do not hitch.
* Deposits and landmarks are capped per planet and destroyed on unload.
* Ship part counts are bounded by `MAX_MODULES`; the default ship builds in ~50
  parts, all welded to a single root.
* Ship transforms broadcast at 10 Hz, not per frame; flight input is coalesced
  client-side and rate-limited server-side.
* `StreamingEnabled` with a 640-stud target radius.

---

## Tests

```bash
npm install
npm test          # whole harness
npm run check     # Luau syntax check of every file in src/
npm run verify    # both
```

The harness (`tools/harness/`) loads the **real** files from `src/` into a Luau
VM and emulates enough Roblox (`Instance`, parts, CFrames, Terrain, attributes,
`Players`, `DataStoreService`, remotes, Heartbeat) to run them. It is not a
Roblox Studio substitute — it cannot test rendering, physics contact, or actual
DataStore round-trips — but it does execute the shipped logic.

Current result:

| suite | assertions |
| --- | --- |
| `01_foundation` — hash, lattice, address format | 17 |
| `02_galaxy` — determinism, biomes, resources | 12 |
| `03_terrain` — heights, chunks, deposits | 13 |
| `04_shipmodel` — module catalogue, blueprint validation | 23 |
| `05_state` — ship state machine, permissions | 14 |
| `06_world` — builds a real ship, streams real terrain | 14 |
| `07_gameplay` — full loop through the real router | 40 |
| `08_contract` — server/client payload shapes | 19 |
| `09_client` — state mirror, UI kit, panels, input mapping | 21 |
| **total** | **173** |

`07_gameplay` is the important one: it fires the real `ClientAction` remote at
the real `ActionRouter` and reads the state the services push back, so it covers
hatch/seat/launch/permission/cooldown/warp/crafting behaviour end to end.

---

## Verification status (honest)

**Executed and passing in this environment**

* Every file compiles with the real Luau compiler (47/47).
* Galaxy/terrain/ship determinism, blueprint validation and stat caps.
* Ship construction: welded hull, sealed cabin, hatch, seat, console.
* Planet streaming: correct chunk count, bounded deposits, unload, identical
  rebuild of the same planet.
* Gameplay through the router: hatch must be closed to launch, only one pilot,
  crew permissions, mining distance/cooldown, scan profile, chart page, address
  lookup, warp range refusal, recipe list, blueprint save/load, rate limiting,
  request-id echo.
* The full ground cycle: seat -> launch -> flight -> timed landing -> back on the
  pad -> hatch opens again, plus releasing a seat (and the owner override).
* Service init is idempotent: booting twice must not double-handle requests.
* Persistence degrades safely when DataStore is unavailable.

**Written and reviewed, but NOT executed (no Roblox Studio here)**

* Anything pixel-visual: what the HUD/panels/touch layer *look* like, and the
  3D workshop preview rig. Their trees are built and exercised in the harness
  (every panel opens/closes, every action-bar button fires, the modal close hook
  runs exactly once, touch and gamepad input map to real flight axes), but
  nobody has seen the result on a screen.
* Physics: whether the welded ship physically carries standing players, whether
  seat/hatch collisions feel right, and flight handling feel. The harness asserts
  structure (welds exist, parts are unanchored, floor friction is high) — that is
  not the same as feeling correct in Studio.
* `ProximityPrompt` behaviour on real devices, gamepad deadzones on real
  hardware, mobile safe-area insets on notched phones.
* Real DataStore reads/writes (the harness has no live DataStore; the failure
  path is what is tested).
* Multiplayer with two live clients. The permission logic is unit-tested, but
  nobody has watched two accounts board the same ship.

**Known limitations**

* One shared expedition per server (no per-crew ships yet).
* Space ↔ surface is a transition, not seamless flight; there is no spherical
  gravity or orbital mechanics. `Descend` is a scripted 2 s transition, and
  `Land` from open flight is a 2.4 s timed descent that sets the ship back on
  the pad of the planet you are over.
* One biome surface per planet, flattened landing pad, no caves or water physics
  beyond a water plane.
* Combat, NPCs, economy and base building are out of scope.
* The workshop grid is a flat XZ board with integer cells; no wings that hang off
  a vertical plane.
* Designs are capped at 4 slots and 36 modules.

---

## Extending it

The code is deliberately free of narrative content, so anything you want to add
has its own obvious place:

* **New content**: add module definitions to `ShipModules.lua` (stats, cost,
  category) and — for new materials — entries in `Config.MATERIALS` plus a recipe
  in `Config.RECIPES`.
* **New biomes**: extend the biome table in `GalaxyGen.lua`; `TerrainGen` derives
  its height/material fields from the biome's parameters.
* **Per-crew expeditions**: `UniverseService`, `ShipService` and `PlanetService`
  already talk to an expedition/ship object rather than globals-in-practice; give
  them a crew id and instantiate one per crew.
* **Quests/story**: nothing in the codebase assumes its absence, but nothing in
  it invents any either. `DiscoveryService` records neutral science-log entries
  (address, biome, temperature) and is the natural hook.

## Licence

Original code written for this project. No third-party assets, paid plugins or
external asset IDs are required; every part, colour and material is defined in
source.
