-- @noindex
-- Fancy Pitch Correct: removing, wiping and clearing pitched items.
-- Part of "Fancy_Pitch Correct.lua", which loads the files of this folder in order (see app.lua).
local App = require("pitch_correct.app")
local K, state = App.K, App.state
local note_own_write = App.note_own_write
local plural = App.plural
local read_take_raw = App.read_take_raw
local request_confirm = App.request_confirm
local reset_analysis_model = App.reset_analysis_model
local resolve_take_by_guid = App.resolve_take_by_guid
local set_status = App.set_status
local switch_active_target = App.switch_active_target

local function strip_pitchenv_from_str(str)
  local s_start = str:find("<PITCHENV")
  if not s_start then return str end
  local depth = 0
  local pos = s_start
  local s_end = nil
  while pos <= #str do
    local b_start, b_end, tag = str:find("([<>])", pos)
    if not b_start then break end
    if tag == "<" then
      depth = depth + 1
    elseif tag == ">" then
      depth = depth - 1
      if depth == 0 then
        if str:sub(b_end + 1, b_end + 2) == "\r\n" then
          s_end = b_end + 2
        elseif str:sub(b_end + 1, b_end + 1) == "\n" then
          s_end = b_end + 1
        else
          s_end = b_end
        end
        break
      end
    end
    pos = b_end + 1
  end

  if s_end then
    return str:sub(1, s_start - 1) .. str:sub(s_end + 1)
  end
  return str
end

local function remove_take_pitch_envelope_chunk(item, take_guid)
  if not item then return end
  local ok, chunk = reaper.GetItemStateChunk(item, "", false)
  if not ok or not chunk or not chunk:find("<PITCHENV") then return end

  local num_takes = reaper.CountTakes(item)
  if num_takes <= 1 or not take_guid then
    local new_chunk = strip_pitchenv_from_str(chunk)
    reaper.SetItemStateChunk(item, new_chunk, false)
    return
  end

  -- Multi-take item: split chunk at "\nTAKE" boundaries
  local sections = {}
  local last_pos = 1
  while true do
    local t_start = chunk:find("\nTAKE", last_pos)
    if not t_start then
      table.insert(sections, chunk:sub(last_pos))
      break
    end
    table.insert(sections, chunk:sub(last_pos, t_start))
    last_pos = t_start + 1
  end

  local modified = false
  for i, sec in ipairs(sections) do
    if sec:find(take_guid, 1, true) then
      local new_sec = strip_pitchenv_from_str(sec)
      if new_sec ~= sec then
        sections[i] = new_sec
        modified = true
      end
      break
    end
  end

  if modified then
    local new_chunk = table.concat(sections, "")
    reaper.SetItemStateChunk(item, new_chunk, false)
  end
end

--- True when the take's pitch algorithm is the one this script writes (state.pitchmode_value), i.e. a
--- reset to the project default only undoes the script's own change and never a value the user chose.
local function script_set_pitch_mode(take)
  if not take or state.pitchmode_value == -1 then return false end
  local current = reaper.GetMediaItemTakeInfo_Value(take, "I_PITCHMODE")
  return current ~= nil and current == state.pitchmode_value
end

--- Remove one item from Pitched Items and clear the script's data on it. Writes to REAPER but opens no
--- undo block: the caller owns it (remove_take_from_session for one item, wipe_entire_session for all).
--- Returns the item name and whether the item was found in the project.
local function remove_take_core(guid)
  local data = state.session_takes[guid]
  local take_name = (data and data.name) or "Item"
  local take_obj = resolve_take_by_guid(guid)

  -- A pending arrow-key nudge on the removed take is discarded with it
  if state.nudge_burst and state.nudge_burst.guid == guid then state.nudge_burst = nil end

  if take_obj then
    local item = reaper.GetMediaItemTake_Item(take_obj)

    -- 1. Wipe all pitch envelope points and automation items first
    local env = reaper.GetTakeEnvelopeByName(take_obj, "Pitch")
    if env then
      local ai_count = reaper.CountAutomationItems(env)
      for a = ai_count - 1, 0, -1 do
        reaper.DestroyAutomationItem(env, a)
      end
      reaper.DeleteEnvelopePointRange(env, -1000000, 1000000)
      reaper.Envelope_SortPoints(env)
    end

    -- 2. Completely remove the <PITCHENV> block from the media item chunk
    if item then
      remove_take_pitch_envelope_chunk(item, guid)
    end

    -- 3. Return the pitch shift mode to the project default (-1), but only when it is the value this
    --    script wrote. The take's own pitch offset (D_PITCH) is the user's and is never touched.
    if script_set_pitch_mode(take_obj) then
      reaper.SetMediaItemTakeInfo_Value(take_obj, "I_PITCHMODE", -1)
    end

    -- 4. Purge persistent project metadata on this take
    reaper.GetSetMediaItemTakeInfo_String(take_obj, K.TAKE_DATA_KEY, "", true)

    if item then
      reaper.UpdateItemInProject(item)
    end
    reaper.UpdateArrange()
  end

  -- 5. Remove from session cache and order
  state.session_takes[guid] = nil
  state.raw_cache[guid] = nil
  state.missing_takes[guid] = nil
  state.stale_takes[guid] = nil
  state.unreadable_takes[guid] = nil
  for idx, g in ipairs(state.session_order) do
    if g == guid then
      table.remove(state.session_order, idx)
      break
    end
  end

  -- 6. If active target was this take, switch to next take or reset to empty
  if state.target_take_guid == guid then
    if #state.session_order > 0 then
      local next_guid = state.session_order[1]
      local next_take = resolve_take_by_guid(next_guid)
      switch_active_target(next_guid, next_take)
    else
      state.target_take_guid = nil
      state.target_take_name = nil
      state.results = {}
      state.notes = nil
      state.analysis_empty = false
      state.selected_note = nil
      state.selected_notes = {}
      state.hovered_note = nil
      state.drag = nil
      state.marquee = nil
      state.point_drag = nil
      state.context_point = nil
      state.hovered_point = nil
      state.point_ghost = nil
      state.points_hover_note = nil
      state.points_zoom_hint = false
      K.reset_view()
      state.start_time = nil
      state.end_time = nil
      state.item_len = nil
      state.sample_rate = nil
    end
  end

  return take_name, take_obj ~= nil
end

--- Remove one take (sidebar X, after the user confirmed): one undo block.
--- Returns the take name and whether the take was found in the project.
local function remove_take_from_session(guid)
  if not guid then return nil, false end

  reaper.Undo_BeginBlock()
  local take_name, found = remove_take_core(guid)
  reaper.Undo_EndBlock(string.format("Remove %s from Pitched Items", take_name), -1)
  note_own_write()
  return take_name, found
end

--- Wipe every item of the session (after the user confirmed) as ONE undo point.
--- Returns the number of items removed.
local function wipe_entire_session()
  local order_copy = {}
  for _, guid in ipairs(state.session_order) do
    table.insert(order_copy, guid)
  end
  local n = #order_copy
  if n == 0 then return 0 end

  reaper.Undo_BeginBlock()
  for _, guid in ipairs(order_copy) do
    remove_take_core(guid)
  end
  -- Every item's envelope was cleared above; only the in-memory analysis is left to drop
  reset_analysis_model()
  state.session_takes = {}
  state.session_order = {}
  state.raw_cache = {}
  state.missing_takes = {}
  state.stale_takes = {}
  reaper.Undo_EndBlock(string.format("Wipe Pitched Items (%d)", n), -1)
  note_own_write()
  return n
end

--- True when the take has a pitch envelope or a stored model to clear (so clearing writes to the project).
local function take_has_clearable_data(take)
  if not take then return false end
  return reaper.GetTakeEnvelopeByName(take, "Pitch") ~= nil or read_take_raw(take) ~= ""
end

--- Clear one take's analysis and pitch envelope points as ONE undo point: the envelope points, the P_EXT
--- model and the session entry go together, so Cmd/Ctrl+Z restores them together (the resync in
--- sync_with_project re-adopts the model when the P_EXT returns).
--- Returns the number of notes cleared and whether an undo point was written.
local function clear_take_analysis(guid)
  if not guid then return 0, false end
  local data = state.session_takes[guid]
  local note_count = (guid == state.target_take_guid and state.notes and #state.notes)
    or (data and data.notes and #data.notes) or 0
  local take = resolve_take_by_guid(guid, true)
  local item = take and reaper.GetMediaItemTake_Item(take)
  local wrote = false

  if take then
    local env = reaper.GetTakeEnvelopeByName(take, "Pitch")
    if take_has_clearable_data(take) then
      wrote = true
      reaper.Undo_BeginBlock()
      if env and item then
        reaper.DeleteEnvelopePointRange(env, 0, reaper.GetMediaItemInfo_Value(item, "D_LENGTH") + 1.0)
        reaper.Envelope_SortPointsEx(env, -1)
      end
      reaper.GetSetMediaItemTakeInfo_String(take, K.TAKE_DATA_KEY, "", true)
      if item then reaper.UpdateItemInProject(item) end
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("Clear Pitch Analysis and Envelope", -1)
      note_own_write()
    end
  end

  -- The model goes with the take data (the row leaves Pitched Items until it is analysed again)
  state.session_takes[guid] = nil
  state.raw_cache[guid] = nil
  state.missing_takes[guid] = nil
  state.stale_takes[guid] = nil
  state.unreadable_takes[guid] = nil
  for idx, g in ipairs(state.session_order) do
    if g == guid then
      table.remove(state.session_order, idx)
      break
    end
  end
  if guid == state.target_take_guid then
    reset_analysis_model()
  end
  return note_count, wrote
end

--- Number of session items whose pitch algorithm a removal would return to the project default.
local function count_pitch_mode_resets(guids)
  local n = 0
  for _, g in ipairs(guids) do
    if script_set_pitch_mode(resolve_take_by_guid(g)) then n = n + 1 end
  end
  return n
end

--- Sidebar X: confirm before removing one item (names the item and every consequence).
local function request_remove_confirm(guid)
  local data = state.session_takes[guid]
  local name = (data and data.name) or "Item"
  local resets_mode = count_pitch_mode_resets({ guid }) > 0
  local lines = {
    string.format("This removes \"%s\" from Pitched Items, deletes its pitch envelope points and clears its saved analysis.", name),
  }
  if resets_mode then
    lines[#lines + 1] = "Its pitch algorithm returns to the project default."
  end
  request_confirm({
    id = "remove_take",
    title = string.format("Remove %s?", name),
    body_lines = lines,
    confirm_label = "Remove",
    on_confirm = function()
      local _, found = remove_take_from_session(guid)
      -- Cmd/Ctrl+Z restores the take's data in REAPER but this list only re-adopts it after the item is
      -- selected again, so the message makes no undo promise
      if found then
        set_status(string.format("Removed %s. Its envelope and saved analysis were cleared.", name))
      else
        set_status(string.format("Removed %s from Pitched Items.", name))
      end
    end,
  })
end

--- Settings > Wipe: confirm before removing every item of the session.
local function request_wipe_confirm()
  local n = #state.session_order
  if n == 0 then return end
  local resets = count_pitch_mode_resets(state.session_order)
  local lines = {
    string.format("This removes all %d pitched %s from Pitched Items, deletes their pitch envelope points and clears their saved analysis.",
      n, plural(n, "item", "items")),
  }
  if resets > 0 then
    lines[#lines + 1] = string.format("The pitch algorithm of %d %s returns to the project default.",
      resets, plural(resets, "item", "items"))
  end
  request_confirm({
    id = "wipe_session",
    title = string.format("Wipe %d %s?", n, plural(n, "item", "items")),
    body_lines = lines,
    confirm_label = string.format("Wipe %d %s", n, plural(n, "Item", "Items")),
    on_confirm = function()
      local wiped = wipe_entire_session()
      -- The list does not re-adopt items after Cmd/Ctrl+Z, so no undo promise
      set_status(string.format("Wiped %d %s.", wiped, plural(wiped, "item", "items")))
    end,
  })
end

--- Settings > Clear: confirm before discarding the active take's analysis and envelope points.
local function request_clear_confirm()
  local guid = state.target_take_guid
  if not guid or not state.notes or #state.notes == 0 then return end
  local name = state.target_take_name or "this item"
  local k = #state.notes
  local lines = {
    string.format("Discards %d %s and the pitch envelope points of this item.", k, plural(k, "note", "notes")),
    "The item leaves Pitched Items until it is analyzed again.",
  }
  if take_has_clearable_data(resolve_take_by_guid(guid, true)) then
    lines[#lines + 1] = string.format("%s+Z brings them back.", K.MOD_LABEL)
  end
  request_confirm({
    id = "clear_take",
    title = string.format("Clear %s?", name),
    body_lines = lines,
    confirm_label = "Clear",
    on_confirm = function()
      local cleared, wrote = clear_take_analysis(guid)
      local msg = string.format("Cleared %d %s.", cleared, plural(cleared, "note", "notes"))
      if wrote then msg = msg .. string.format(" %s+Z to undo", K.MOD_LABEL) end
      set_status(msg)
    end,
  })
end

--- The items (take GUIDs, sorted) whose saved analysis could not be read and which exist in the project now.
K.unreadable_guids = function()
  local list = {}
  for guid in pairs(state.unreadable_takes) do
    if resolve_take_by_guid(guid, true) then list[#list + 1] = guid end
  end
  table.sort(list)
  return list
end

--- Purge the saved data of every unreadable item as ONE undo point ("Clear Unreadable Pitched Items Data"). An item that
--- was listed leaves Pitched Items like any cleared analysis. Returns how many items were purged.
K.clear_unreadable = function()
  local guids = K.unreadable_guids()
  if #guids == 0 then return 0 end
  reaper.Undo_BeginBlock()
  for _, guid in ipairs(guids) do
    local take = resolve_take_by_guid(guid, true)
    if take then reaper.GetSetMediaItemTakeInfo_String(take, K.TAKE_DATA_KEY, "", true) end
    state.unreadable_takes[guid] = nil
    state.raw_cache[guid] = nil
    if state.session_takes[guid] then
      state.session_takes[guid] = nil
      state.missing_takes[guid] = nil
      state.stale_takes[guid] = nil
      for idx, g in ipairs(state.session_order) do
        if g == guid then
          table.remove(state.session_order, idx)
          break
        end
      end
      if guid == state.target_take_guid then reset_analysis_model() end
    end
  end
  reaper.Undo_EndBlock("Clear Unreadable Pitched Items Data", -1)
  note_own_write()
  return #guids
end

--- Pitched Items banner "Clear": confirm before purging the unreadable saved data (names the count).
K.request_clear_unreadable = function()
  local n = #K.unreadable_guids()
  if n == 0 then return end
  request_confirm({
    id = "clear_unreadable",
    title = "Clear unreadable saved data?",
    body_lines = {
      string.format("Clear the unreadable saved data of %d %s? Their Pitched Items entry can be analyzed again.",
        n, plural(n, "item", "items")),
    },
    confirm_label = "Clear",
    on_confirm = function()
      local cleared = K.clear_unreadable()
      set_status(string.format("Cleared the unreadable saved data of %d %s.", cleared, plural(cleared, "item", "items")))
    end,
  })
end

-- What the files loaded after this one use
App.request_clear_confirm = request_clear_confirm
App.request_remove_confirm = request_remove_confirm
App.request_wipe_confirm = request_wipe_confirm
App.script_set_pitch_mode = script_set_pitch_mode
