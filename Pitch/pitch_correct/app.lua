-- @noindex
-- Fancy Pitch Correct: the table every part of the script shares.
-- "Fancy_Pitch Correct.lua" fills in what it creates (the ImGui context, the fonts, the option lists) and then
-- loads the other files of this folder in order; each one reads what it needs from this table at the top and
-- adds what the later ones use at the bottom. Not a script of its own.
return {}
