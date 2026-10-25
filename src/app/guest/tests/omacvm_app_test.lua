-- omacvm_app.lua sets the outputs' kept rules again while Hyprland loads its
-- config (an Omarchy theme switch reloads it), against a fake Hyprland.
-- Run: d=$(mktemp -d); XDG_RUNTIME_DIR=$d XDG_CONFIG_HOME=$d lua src/app/guest/tests/omacvm_app_test.lua src/app/guest/omacvm_app.lua
-- (Lua 5.4.)
local modpath = arg[1]
local rt = os.getenv("XDG_RUNTIME_DIR")
local cfg = os.getenv("XDG_CONFIG_HOME")
assert(modpath and rt and cfg and rt ~= "", "usage: see the top of this file")
os.execute("mkdir -p '" .. rt .. "/omacvm/display-sync' '" .. cfg .. "/hypr'")

local monitors, applied, window_rules, configs
hl = {
  get_monitors = function() return monitors end,
  monitor = function(rule) applied[#applied + 1] = rule end,
  window_rule = function(rule) window_rules[#window_rules + 1] = rule end,
  config = function(c) configs[#configs + 1] = c end,
  on = function() end,
  timer = function() end,
  exec_cmd = function() end,
}

local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local function rule_file(output, text) write(rt .. "/omacvm/display-sync/" .. output .. ".rule", text) end

local function load_config(names)
  monitors, applied, window_rules, configs = {}, {}, {}, {}
  for _, n in ipairs(names) do monitors[#monitors + 1] = { name = n } end
  dofile(modpath)
  return applied
end

local failed = 0
local function check(name, ok)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failed = failed + 1 end
end

local MODE = "modeline 453 2940 3675 3763 3969 1840 1849 1858 1904 -hsync -vsync"
write(cfg .. "/hypr/monitors.lua",
  'local omarchy_monitor_scale = 2\nhl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })\n')

-- Nothing kept yet (first login): no rule.
check("no kept rule: nothing set", #load_config({ "Virtual-1", "NOTCH" }) == 0)

-- Hyprland's unmodified SDR copy of each HDR frame only while something
-- captures the output (render:keep_unmodified_copy 0), at every load.
local keep
for _, c in ipairs(configs) do
  if c.render and c.render.keep_unmodified_copy ~= nil then keep = c.render.keep_unmodified_copy end
end
check("HDR: SDR copy for captures only", keep == 0)

-- The screen's kept rule comes back as it was sent (Omanotch's NOTCH output
-- above it can no longer push it aside with "auto").
rule_file("Virtual-1", 'hl.monitor({ output = "Virtual-1", mode = "' .. MODE .. '", position = "0x0", scale = "2" })\n')
local got = load_config({ "Virtual-1", "NOTCH" })
check("kept rule set again", #got == 1 and got[1].output == "Virtual-1" and got[1].mode == MODE
  and got[1].position == "0x0" and got[1].scale == "2")

-- An external display's rule too, with the HDR fields (numbers stay numbers).
rule_file("Virtual-2", 'hl.monitor({ output = "Virtual-2", mode = "modeline 533 3840 3888 3920 4000 2160 2163 2168 2222 +hsync -vsync", '
  .. 'position = "-480x-1080", scale = "auto", bitdepth = 10, cm = "hdr", supports_wide_color = 1, supports_hdr = 1, '
  .. 'max_luminance = 1600, min_luminance = 0.0005, sdr_max_luminance = 203 })\n')
got = load_config({ "Virtual-1", "Virtual-2", "NOTCH" })
local v2
for _, r in ipairs(got) do if r.output == "Virtual-2" then v2 = r end end
check("both outputs", #got == 2)
check("external's place and HDR fields", v2 and v2.position == "-480x-1080" and v2.bitdepth == 10 and v2.cm == "hdr"
  and v2.max_luminance == 1600 and v2.min_luminance == 0.0005 and v2.sdr_max_luminance == 203)

check("no window rule for an external's HDR fields", #window_rules == 0)

-- The screen in PQ (HDR): windows clipped at max_luminance again, not
-- tone-mapped (display-sync's hdr_tonemap); a reload dropped that rule.
local HDR_RULE = 'hl.monitor({ output = "Virtual-1", mode = "' .. MODE .. '", position = "0x0", scale = "2", '
  .. 'bitdepth = 10, cm = "hdr", supports_wide_color = 1, supports_hdr = 1, max_luminance = 406, '
  .. 'min_luminance = 0.0005, sdr_max_luminance = 203 })\n'
rule_file("Virtual-1", HDR_RULE)
got = load_config({ "Virtual-1", "NOTCH" })
local wr = window_rules[1]
check("PQ screen: its rule", #got == 1 and got[1].cm == "hdr" and got[1].max_luminance == 406)
check("PQ screen: windows clipped", #window_rules == 1 and wr.name == "omacvm-hdr" and wr.tonemap == "clamp"
  and wr.match and wr.match.class == ".*")
rule_file("Virtual-1", 'hl.monitor({ output = "Virtual-1", mode = "' .. MODE .. '", position = "0x0", scale = "2", '
  .. 'bitdepth = 10, cm = "srgb" })\n')
load_config({ "Virtual-1", "NOTCH" })
check("10-bit sRGB screen: no window rule", #window_rules == 0)
rule_file("Virtual-1", 'hl.monitor({ output = "Virtual-1", mode = "' .. MODE .. '", position = "0x0", scale = "2" })\n')
load_config({ "Virtual-1", "NOTCH" })
check("SDR screen: no window rule", #window_rules == 0)
rule_file("Virtual-1", HDR_RULE)
write(cfg .. "/hypr/monitors.lua",
  'hl.monitor({ output = "Virtual-1", mode = "1920x1200@60", position = "0x0", scale = 1 })\n')
load_config({ "Virtual-1", "NOTCH" })
check("user's own rule for the screen: no window rule", #window_rules == 0)
write(cfg .. "/hypr/monitors.lua",
  'local omarchy_monitor_scale = 2\nhl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })\n')
rule_file("Virtual-1", 'hl.monitor({ output = "Virtual-1", mode = "' .. MODE .. '", position = "0x0", scale = "2" })\n')

-- A display that left (the Mac's other screen left full screen): not set.
got = load_config({ "Virtual-1", "NOTCH" })
check("gone output not set", #got == 1 and got[1].output == "Virtual-1")
os.remove(rt .. "/omacvm/display-sync/Virtual-2.rule")

-- The user's own rule for the screen in monitors.lua wins.
write(cfg .. "/hypr/monitors.lua",
  'hl.monitor({ output = "Virtual-1", mode = "1920x1200@60", position = "0x0", scale = 1 })\n')
check("user's own rule: not set", #load_config({ "Virtual-1", "NOTCH" }) == 0)
-- ... but not one that is commented out.
write(cfg .. "/hypr/monitors.lua",
  '-- hl.monitor({ output = "Virtual-1", mode = "1920x1200@60", position = "0x0", scale = 1 })\n')
check("commented-out user rule: set", #load_config({ "Virtual-1", "NOTCH" }) == 1)

-- Only plain values are read; a file that is not a kept rule is ignored and
-- nothing in it runs.
rule_file("Virtual-1", 'os.exit(3) hl.monitor({ output = "Virtual-1", mode = "' .. MODE .. '", position = "0x0", scale = "2" })\n')
check("not a rule: ignored", #load_config({ "Virtual-1" }) == 0)
rule_file("Virtual-1", 'hl.monitor({ output = "Virtual-1", mode = os.exit(3), position = "0x0", scale = "2" })\n')
check("code in a field: ignored", #load_config({ "Virtual-1" }) == 0)
rule_file("Virtual-1", 'hl.monitor({ output = "NOTCH", mode = "' .. MODE .. '", position = "0x0", scale = "2" })\n')
check("rule for another output: ignored", #load_config({ "Virtual-1", "NOTCH" }) == 0)
rule_file("Virtual-1", "")
check("empty file: ignored", #load_config({ "Virtual-1" }) == 0)

if failed > 0 then
  print(failed .. " failed")
  os.exit(1)
end
print("all passed")
