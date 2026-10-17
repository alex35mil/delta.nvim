# Brief

Fix the reproduced window-destruction bug in delta.nvim’s picker lifecycle.

In headless Neovim with `-u NONE`, create three ordinary editing windows and immediately call `picker.toggle({ source = "git" })` three times: open → close while loading → reopen. Closing destroys two editing windows, and pending Git work produces `lua/delta/picker/ui.lua:1650: Invalid window id` errors.

`M.show` initializes window IDs to `0`; `M.close` treats these as valid and closes the current editing windows. Asynchronous work also outlives its picker instance and accesses shared state belonging to a newer instance.

Fix lifecycle and state ownership rather than only guarding the failing line. Closing during loading must preserve editing windows and buffers. Obsolete asynchronous work must not mutate or create windows for a later picker instance.

Inspect affected asynchronous consumers. Add regression coverage for closing before loading completes, closing and reopening with old work pending, preservation of editing windows and buffers, and ordinary picker opening/closing.

Verify in headless Neovim, run relevant tests, and follow `AGENTS.md`.
