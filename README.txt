Open a terminal where you extracted the the .ps1 file and run:
powershell -ExecutionPolicy Bypass -File lua_hookv1_repl.ps1
Or run the .bat file.

A lot of the methods / functions listed in methods.txt don't work or the intended usage is unclear. This is just what was found, not what works.

Game state access:
local gt = GameObject:GetTable()

Always first use 'if GameObject then' before changing gamestate to increase stability.

GetPlayer() doesn't seem to work, iterate GetPlayers() like:
'if GameObject then local ps=GameObject:GetTable():GetPlayers() for i,p in pairs(ps) do if p:GetName()=="Max" then p:Fold() break end end end'

Valid player names:
"Max", "Tycho", "Heavy", "Strongbad", "Player"