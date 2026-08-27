import re
import sys

with open("FX/Fancy_Parameter Link.lua", "r") as f:
    content = f.read()

# 1. Update @provides
content = re.sub(
    r'-- @provides\n--   \[main\] \.',
    r'-- @provides\n--   [main] .\n--   [nomain] ../_lib/*.lua',
    content
)

# 2. Bump version and changelog
content = re.sub(
    r'-- @version 4\.0\.0\n-- @changelog\n--   \+ Added ReaPack distribution support',
    r'-- @version 4.1.0\n-- @changelog\n--   + Migrated to shared _lib/ modules (theme, json, utils)',
    content
)

# 4. Remove TINY JSON LIBRARY (doing this before inserting the bootstrap)
content = re.sub(
    r'-- 2\. TINY JSON LIBRARY\n-*\nlocal JSON = \{\}\n\n.*?function JSON\.decode\s*\(str\).*?return parse\(\)\s*end\n',
    r'-- 2. SHARED LIBRARY BOOTSTRAP\n' + '-'*79 + '\n' +
    r'local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])' + '\n' +
    r'package.path = script_dir .. "../_lib/?.lua;" .. package.path' + '\n\n' +
    r'local Theme = require("theme")' + '\n' +
    r'local JSON  = require("json")',
    content,
    flags=re.DOTALL
)

# 6. Replace color palette definition
content = re.sub(
    r'local C = \{\n\s*bg\s*=\s*0x[0-9A-Fa-f]+,\n.*?dim_bg\s*=\s*0x[0-9A-Fa-f]+,\n\}',
    r'local C = Theme.build_palette()',
    content,
    flags=re.DOTALL
)

# 7. Remove push_theme() and pop_theme()
content = re.sub(
    r'local function push_theme\(\)\n.*?return 28, 4\nend\n\nlocal function pop_theme\(nc, nv\)\n.*?end\n',
    r'',
    content,
    flags=re.DOTALL
)

# 8. Update calls
content = content.replace('local nc, nv = push_theme()', 'local nc, nv = Theme.push(ctx, C)')
content = content.replace('pop_theme(nc, nv)', 'Theme.pop(ctx, nc, nv)')

# 9. Rename C field references
content = re.sub(r'\bC\.acc_h\b', 'C.accent_h', content)
content = re.sub(r'\bC\.acc_d\b', 'C.accent_d', content)
content = re.sub(r'\bC\.acc_e\b', 'C.accent_e', content)
content = re.sub(r'\bC\.acc\b', 'C.accent', content)
content = re.sub(r'\bC\.grn_d\b', 'C.green_d', content)
content = re.sub(r'\bC\.grn_h\b', 'C.green_h', content)
content = re.sub(r'\bC\.grn\b', 'C.green', content)
content = re.sub(r'\bC\.yel\b', 'C.yellow', content)
content = re.sub(r'\bC\.dim\b', 'C.text_dim', content)

with open("FX/Fancy_Parameter Link.lua", "w") as f:
    f.write(content)

print("Done")
