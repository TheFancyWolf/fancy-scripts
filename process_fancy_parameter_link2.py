import re
import sys

with open("FX/Fancy_Parameter Link.lua", "r") as f:
    content = f.read()

content = re.sub(
    r'-- 2\. TINY JSON LIBRARY\n-*\nlocal JSON = \{\}\n\n.*?function JSON\.decode\(s\).*?return parse\(\)\nend\n',
    r'-- 2. SHARED LIBRARY BOOTSTRAP\n' + '-'*79 + '\n' +
    r'local script_dir = debug.getinfo(1, "S").source:match([[^@?(.*[\/])[^\/]-$]])' + '\n' +
    r'package.path = script_dir .. "../_lib/?.lua;" .. package.path' + '\n\n' +
    r'local Theme = require("theme")' + '\n' +
    r'local JSON  = require("json")' + '\n' +
    r'local Utils = require("utils")\n',
    content,
    flags=re.DOTALL
)

with open("FX/Fancy_Parameter Link.lua", "w") as f:
    f.write(content)

print("Done")
