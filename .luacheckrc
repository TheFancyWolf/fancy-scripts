std = "lua54"

-- Agent tooling is never shipped or linted as REAPER code.
exclude_files = { ".agents/**", ".claude/**" }

globals = {
  "reaper",
  "gfx",
}

read_globals = {
  "ImGui",
}

max_line_length = false

unused_args = true
ignore = {
  "212/_.*",  -- unused argument starting with _
}
