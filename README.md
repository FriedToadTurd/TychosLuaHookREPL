# TychosLuaHookREPL
Made for Tychos Lua Hook, a Lua hook for Poker Night at the Inventory (2026). 
Also contains a large collection of found methods.
**Requires Tycho's Lua Hook from Nexusmods**

## Running the Script

Open a terminal in the folder where you extracted the `.ps1` file and run:

```
powershell -ExecutionPolicy Bypass -File lua_hookv1_repl.ps1
```

---

## Notes on Methods

- Many of the methods/functions listed in `methods.txt`:
  - Do **not work**, or
  - Have **unclear intended usage**
- This list represents what was discovered, **not what is confirmed to work**

---

## Game State Access

```lua
local gt = GameObject:GetTable()
```

Always check for `GameObject` before modifying game state to improve stability:

```lua
if GameObject then
    -- your code here
end
```

---

## Accessing Players

`GetPlayer()` does **not** appear to work correctly.  
Instead, iterate through `GetPlayers()`:

```
if GameObject then local ps=GameObject:GetTable():GetPlayers() for i,p in pairs(ps) do if p:GetName()=="Max" then p:Fold() break end end end
```

---

## Valid Player Names

- `"Max"`
- `"Tycho"`
- `"Heavy"`
- `"Strongbad"`
- `"Player"`
