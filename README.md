# HD2-Death-Recap
shows who killed you (pvp only)  in Helldivers 2 when its a teammate. Displays killers nickname total damage last hit and HP before death requires HD2Runtime

## What it does

When you die from **friendly fire** a panel appears on screen for 10 seconds:

KILLED BY: killers name
Damage: 122 over 12 hits
Last hit: 45
HP before death: 0 / 125

If an enemy kills you the panel stays hidden this mod is !PvP focused!

## Requirements

- **Bingus Shared Loader v18+**
- **HD2Runtime v0.28.1+** (by SkyeShade)
- Both must be loaded **before** this mod

## Installation

1. Install via **Arsenal** or any HD2 mod manager.
2. Make sure load order is:
   - Bingus Shared Loader (highest priority / bottom)
   - HD2Runtime
   - **HD2 Death Recap**
3. Purge deploy and restart the game.

## How it works

- Reads the player roster directly from `game.dll` at `base + 0x347ced8`.
- Each entry is 0xC0 bytes: peer ID at +0x00, persona name at +0x08.
- Subscribes to HD2Runtime events: `player_damaged` (filters teammate hits only) and `player_died`.
- Renders the panel through Stingray GUI (`_G.stingray`).

All reads. Never writes to game memory.

## What it does NOT do

- Does not show enemy kills.
- Does not show your own kills.
- Does not show who killed whom within the squad without you.
- Does not modify game state.

## Safety

- Read-only. Never calls `WriteProcessMemory`, `VirtualProtect`, or any write API.
- No external process memory reads.
- Works within game's LuaJIT VM only.

## Known limitations

- Requires the exact `game.dll` build (roster offset is fixed to Steam build 25480438). Game updates may require re-checking the offset.
- Runtime must expose `_G.stingray` for the GUI to render.
- Enemy killer names require Runtime to expose `attacker_peer` for enemies — currently it does not.

## License

MIT - do whatever you want, no warranty.
