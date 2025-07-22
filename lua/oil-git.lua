local M = {}

-- Default highlight colors (only used if not already defined)
local default_highlights = {
	OilGitAdded = { fg = "#a6e3a1" },
	OilGitModified = { fg = "#f9e2af" },
	OilGitRenamed = { fg = "#cba6f7" },
	OilGitUntracked = { fg = "#89b4fa" },
	OilGitIgnored = { fg = "#6c7086" },
	-- Directory highlights (slightly dimmed versions)
	OilGitDirAdded = { fg = "#a6e3a1" },
	OilGitDirModified = { fg = "#f9e2af" },
	OilGitDirRenamed = { fg = "#cba6f7" },
	OilGitDirUntracked = { fg = "#89b4fa" },
	OilGitDirIgnored = { fg = "#6c7086" },
}

-- Debouncing variables
local refresh_timer = nil
local DEBOUNCE_MS = 50
local last_refresh_time = 0
local MIN_REFRESH_INTERVAL = 200 -- Minimum 200ms between actual refreshes

-- Periodic refresh for external changes (disabled by default to prevent cursor blinking)
local periodic_timer = nil
local PERIODIC_REFRESH_MS = nil -- Disabled by default

-- Cache to prevent unnecessary refreshes
local last_refresh_state = {
	dir = nil,
	git_status_hash = nil,
	buffer_lines_hash = nil,
}

-- Debug flag - configurable via setup options
local DEBUG = false

local function debug_log(msg, level)
	if DEBUG then
		vim.notify("[oil-git] " .. msg, level or vim.log.levels.INFO)
	end
end

local function setup_highlights()
	-- Only set highlight if it doesn't already exist (respects colorscheme)
	debug_log("SETUP_HIGHLIGHTS: Setting up highlight groups")
	for name, opts in pairs(default_highlights) do
		if vim.fn.hlexists(name) == 0 then
			vim.api.nvim_set_hl(0, name, opts)
			debug_log("  Created highlight group: " .. name)
		else
			debug_log("  Highlight group already exists: " .. name)
		end
	end
	
	-- Verify directory highlight groups specifically
	local dir_groups = {"OilGitDirAdded", "OilGitDirModified", "OilGitDirRenamed", "OilGitDirUntracked", "OilGitDirIgnored"}
	for _, group in ipairs(dir_groups) do
		local exists = vim.fn.hlexists(group) == 1
		debug_log("  Directory highlight group " .. group .. ": " .. (exists and "EXISTS" or "MISSING"))
	end
end

local function get_git_root(path)
	local git_dir = vim.fn.finddir(".git", path .. ";")
	if git_dir == "" then
		return nil
	end
	-- Get the parent directory of .git, not .git itself
	return vim.fn.fnamemodify(git_dir, ":p:h:h")
end

local function get_git_status(dir)
	local git_root = get_git_root(dir)
	if not git_root then
		return {}
	end

	local cmd = string.format("cd %s && git status --porcelain --ignored", vim.fn.shellescape(git_root))
	local output = vim.fn.system(cmd)

	if vim.v.shell_error ~= 0 then
		return {}
	end

	local status = {}
	for line in output:gmatch("[^\r\n]+") do
		if #line >= 3 then
			local status_code = line:sub(1, 2)
			local filepath = line:sub(4)

			-- Handle renames (format: "old-name -> new-name")
			if status_code:sub(1, 1) == "R" then
				local arrow_pos = filepath:find(" %-> ")
				if arrow_pos then
					filepath = filepath:sub(arrow_pos + 4)
				end
			end

			-- Remove leading "./" if present
			if filepath:sub(1, 2) == "./" then
				filepath = filepath:sub(3)
			end

			-- Convert to absolute path
			local abs_path = git_root .. "/" .. filepath

			status[abs_path] = status_code
		end
	end

	return status
end

-- Check if a directory contains files with git changes
local function get_directory_status(dir_path, git_status)
	local dir_path_normalized = dir_path:gsub("/$", "") .. "/"
	debug_log("  DIR STATUS CHECK: Looking for files in '" .. dir_path_normalized .. "'")
	
	local status_priority = {
		["A"] = 4, -- Added (highest priority)
		["M"] = 3, -- Modified
		["R"] = 2, -- Renamed
		["?"] = 1, -- Untracked
		["!"] = 0, -- Ignored (lowest priority)
	}

	local highest_priority = -1
	local highest_status = nil
	local found_files = {}

	for filepath, status_code in pairs(git_status) do
		-- Check if this file is within the directory
		if filepath:sub(1, #dir_path_normalized) == dir_path_normalized then
			table.insert(found_files, filepath .. " (" .. status_code .. ")")
			local first_char = status_code:sub(1, 1)
			local second_char = status_code:sub(2, 2)

			-- Check both staged and unstaged changes
			for _, char in ipairs({ first_char, second_char }) do
				local priority = status_priority[char]
				if priority and priority > highest_priority then
					highest_priority = priority
					highest_status = char .. char -- Convert single char to status code format
				end
			end
		end
	end

	debug_log("  DIR STATUS RESULT: Found " .. #found_files .. " files, status: " .. (highest_status or "none"))
	if #found_files > 0 then
		debug_log("    Files: " .. table.concat(found_files, ", "))
	end
	
	return highest_status
end

local function get_highlight_group(status_code, is_directory)
	if not status_code then
		return nil, nil
	end

	local first_char = status_code:sub(1, 1)
	local second_char = status_code:sub(2, 2)

	local prefix = is_directory and "OilGitDir" or "OilGit"

	-- Check staged changes first (prioritize staged over unstaged)
	if first_char == "A" then
		return prefix .. "Added", "+"
	elseif first_char == "M" then
		return prefix .. "Modified", "~"
	elseif first_char == "R" then
		return prefix .. "Renamed", "â†'"
	end

	-- Check unstaged changes
	if second_char == "M" then
		return prefix .. "Modified", "~"
	end

	-- Untracked files
	if status_code == "??" then
		return prefix .. "Untracked", "?"
	end

	-- Ignored files
	if status_code == "!!" then
		return prefix .. "Ignored", "!"
	end

	return nil, nil
end

-- Store extmarks for proper cleanup
local highlight_namespace = vim.api.nvim_create_namespace("oil_git_highlights")
local symbol_namespace = vim.api.nvim_create_namespace("oil_git_symbols")

local function clear_highlights()
	-- Clear highlights from current buffer
	local bufnr = vim.api.nvim_get_current_buf()
	if vim.api.nvim_buf_is_valid(bufnr) then
		-- Clear all our highlights and symbols using namespaces
		vim.api.nvim_buf_clear_namespace(bufnr, highlight_namespace, 0, -1)
		vim.api.nvim_buf_clear_namespace(bufnr, symbol_namespace, 0, -1)
		
		-- Also clear any window-local matches (fallback for old highlights)
		pcall(vim.fn.clearmatches)
	end
	
	-- Also clear from all oil buffers to prevent leftover highlights
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "oil" then
			vim.api.nvim_buf_clear_namespace(buf, highlight_namespace, 0, -1)
			vim.api.nvim_buf_clear_namespace(buf, symbol_namespace, 0, -1)
		end
	end
	
	debug_log("*** CLEAR_HIGHLIGHTS completed - all highlights wiped from all oil buffers")
end

-- Simple hash function for change detection
local function simple_hash(data)
	local hash = 0
	local str = vim.inspect(data)
	for i = 1, #str do
		hash = (hash * 31 + string.byte(str, i)) % 2147483647
	end
	return hash
end

-- Check if refresh is needed based on content changes
local function should_refresh(current_dir, git_status, buffer_lines)
	local git_hash = simple_hash(git_status)
	local lines_hash = simple_hash(buffer_lines)

	local dir_changed = last_refresh_state.dir ~= current_dir
	local git_changed = last_refresh_state.git_status_hash ~= git_hash
	local lines_changed = last_refresh_state.buffer_lines_hash ~= lines_hash

	if dir_changed or git_changed or lines_changed then
		debug_log(
			string.format(
				"should_refresh: YES (dir:%s git:%s lines:%s)",
				tostring(dir_changed),
				tostring(git_changed),
				tostring(lines_changed)
			)
		)

		last_refresh_state.dir = current_dir
		last_refresh_state.git_status_hash = git_hash
		last_refresh_state.buffer_lines_hash = lines_hash
		return true
	end

	debug_log("should_refresh: NO - no changes detected")
	return false
end

local function apply_git_highlights()
	debug_log("apply_git_highlights called")
	local oil = require("oil")
	local current_dir = oil.get_current_dir()

	if not current_dir then
		debug_log("no current_dir, clearing highlights")
		clear_highlights()
		last_refresh_state = { dir = nil, git_status_hash = nil, buffer_lines_hash = nil }
		return
	end

	debug_log("current_dir: " .. current_dir)
	local git_status = get_git_status(current_dir)
	if vim.tbl_isempty(git_status) then
		debug_log("no git status - checking if we need to clear highlights")
		-- Only clear highlights if we previously had some
		if last_refresh_state.git_status_hash and last_refresh_state.git_status_hash ~= simple_hash({}) then
			debug_log("clearing highlights - had previous git status")
			clear_highlights()
		else
			debug_log("no highlights to clear - no previous git status")
		end
		last_refresh_state = { dir = current_dir, git_status_hash = simple_hash({}), buffer_lines_hash = nil }
		return
	end

	debug_log("found " .. vim.tbl_count(git_status) .. " git status entries")
	debug_log("*** Getting buffer info - POTENTIAL CURSOR BLINK!")
	local bufnr = vim.api.nvim_get_current_buf()
	debug_log("Buffer number: " .. bufnr)

	-- Validate buffer is still valid and is an oil buffer
	debug_log("Validating buffer...")
	if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "oil" then
		debug_log("invalid buffer or not oil filetype")
		return
	end

	debug_log("Getting buffer lines - POTENTIAL CURSOR BLINK!")
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	debug_log("Got " .. #lines .. " lines from buffer")

	debug_log("applying highlights - always wiping and reapplying all")

	-- ALWAYS clear all highlights first to ensure clean state
	clear_highlights()

	-- Process each line for git status highlighting

	for i, line in ipairs(lines) do
		local entry = oil.get_entry_on_line(bufnr, i)
		if entry then
			local status_code = nil
			local is_directory = entry.type == "directory"

			if entry.type == "file" then
				-- For files, check direct git status
				local filepath = current_dir .. entry.name
				status_code = git_status[filepath]
			elseif entry.type == "directory" then
				-- For directories, check if they contain modified files
				local dirpath = current_dir .. entry.name
				status_code = get_directory_status(dirpath, git_status)
				debug_log("directory " .. entry.name .. " status: " .. (status_code or "none"))
			end

			local hl_group, symbol = get_highlight_group(status_code, is_directory)

			if hl_group and symbol then
				debug_log("Processing entry: '" .. entry.name .. "' (type: " .. entry.type .. ") in line: '" .. line .. "'")
				debug_log("  Status code: " .. (status_code or "none") .. ", Highlight: " .. hl_group .. ", Symbol: " .. symbol)
				
				-- Use a more robust approach to find and highlight filenames
				-- This works regardless of how oil formats the filename (with or without quotes, spaces, etc.)
				
				-- Try to find the actual filename boundaries for more precise highlighting
				local name_start, name_end = nil, nil
				
				-- Method 1: Look for the filename exactly as oil displays it
				local display_patterns = {
					entry.name,  -- exact match
					'"' .. entry.name .. '"',  -- quoted
					"'" .. entry.name .. "'",  -- single quoted
				}
				
				-- For directories, also try with trailing slash
				if is_directory then
					table.insert(display_patterns, entry.name .. "/")
					table.insert(display_patterns, '"' .. entry.name .. '/"')
					table.insert(display_patterns, "'" .. entry.name .. "/'")
				end
				
				for _, pattern in ipairs(display_patterns) do
					local start_pos = line:find(pattern, 1, true)
					if start_pos then
						name_start = start_pos
						name_end = start_pos + #pattern - 1
						-- If quoted, adjust to highlight just the filename
						if pattern:sub(1,1) == '"' or pattern:sub(1,1) == "'" then
							name_start = name_start + 1
							name_end = name_end - 1
						end
						debug_log("  Method 1 SUCCESS: Found pattern '" .. pattern .. "' at " .. start_pos .. "-" .. name_end)
						break
					else
						debug_log("  Method 1: Pattern '" .. pattern .. "' NOT found in line")
					end
				end
				
				-- Method 2: If exact match fails, use oil's column information
				if not name_start then
					-- Oil typically shows files in a consistent column layout
					-- Find the first non-whitespace character (skip icons)
					local content_start = line:find("%S")
					if content_start then
						-- Look for filename-like content starting from there
						local filename_pattern = "[%w%s%.%-_/]+"  -- Include slash for directories
						local match_start, match_end = line:find(filename_pattern, content_start)
						if match_start then
							local matched_text = line:sub(match_start, match_end)
							-- Check if the matched text contains our entry name
							local escaped_name = entry.name:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
							local pattern_name = escaped_name:gsub(" ", ".*")
							if matched_text:find(pattern_name) then
								name_start = match_start
								name_end = match_end
								debug_log("Method 2 found: '" .. matched_text .. "' for entry: '" .. entry.name .. "'")
							end
						end
					end
				end
				
				-- Method 3: Fallback - highlight from first non-space to end of visible content
				if not name_start then
					local content_start = line:find("%S")
					local content_end = line:find("%s*$") - 1
					if content_start and content_end >= content_start then
						name_start = content_start
						name_end = content_end
					end
				end
				
				-- Apply highlighting using extmarks (more reliable than matchaddpos)
				if name_start and name_end then
					local col_start = name_start - 1  -- 0-indexed for extmarks
					local col_end = name_end  -- exclusive end
					
					-- For directories, try to include trailing slash
					if is_directory and name_end < #line and line:sub(name_end + 1, name_end + 1) == "/" then
						col_end = col_end + 1
					end
					
					debug_log(string.format("Highlighting '%s' from col %d to %d", entry.name, col_start, col_end))
					debug_log("  Highlight group: " .. hl_group .. " (exists: " .. tostring(vim.fn.hlexists(hl_group) == 1) .. ")")
					
					-- Use extmarks for highlighting (more reliable cleanup)
					local success, err = pcall(vim.api.nvim_buf_set_extmark, bufnr, highlight_namespace, i - 1, col_start, {
						end_col = col_end,
						hl_group = hl_group,
						priority = 100,  -- Higher priority to override other highlights
					})
					debug_log("  Extmark application: " .. (success and "SUCCESS" or ("FAILED: " .. tostring(err))))
					
					-- Add symbol as virtual text at the end of the line
					pcall(vim.api.nvim_buf_set_extmark, bufnr, symbol_namespace, i - 1, 0, {
						virt_text = { { " " .. symbol, hl_group } },
						virt_text_pos = "eol",
						hl_mode = "combine",
						priority = 100,
					})
				else
					debug_log("Could not determine highlight position for: '" .. entry.name .. "' in line: '" .. line .. "'")
				end
			end
		end
	end
end

-- Lightweight check for git changes without applying highlights
local function check_git_changes_only()
	debug_log("*** CHECK_GIT_CHANGES_ONLY called - POTENTIAL CURSOR BLINK!")
	local oil = require("oil")
	debug_log("Getting oil.get_current_dir() - POTENTIAL CURSOR BLINK!")
	local current_dir = oil.get_current_dir()
	debug_log("Got current_dir: " .. (current_dir or "nil"))

	if not current_dir then
		debug_log("No current_dir, returning false")
		return false
	end

	debug_log("Calling get_git_status() - POTENTIAL CURSOR BLINK!")
	local git_status = get_git_status(current_dir)
	debug_log("Got git_status with " .. vim.tbl_count(git_status) .. " entries")

	debug_log("Calling simple_hash() - POTENTIAL CURSOR BLINK!")
	local git_hash = simple_hash(git_status)
	debug_log("Got git_hash: " .. git_hash)

	-- Only return true if git status actually changed
	if last_refresh_state.git_status_hash ~= git_hash then
		debug_log("periodic check: git status changed")
		return true
	end

	debug_log("periodic check: no git changes")
	return false
end

-- Check if oil buffer is ready for highlighting
local function is_oil_buffer_ready()
	if vim.bo.filetype ~= "oil" then
		return false
	end
	
	local oil = require("oil")
	local current_dir = oil.get_current_dir()
	if not current_dir then
		debug_log("oil buffer not ready - no current_dir")
		return false
	end
	
	-- Check if buffer has content
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	if #lines == 0 or (#lines == 1 and lines[1] == "") then
		debug_log("oil buffer not ready - no content")
		return false
	end
	
	-- Check if oil can get entries (buffer is fully loaded)
	local has_entries = false
	for i = 1, math.min(#lines, 5) do  -- Check first few lines
		local entry = oil.get_entry_on_line(0, i)
		if entry then
			has_entries = true
			break
		end
	end
	
	if not has_entries then
		debug_log("oil buffer not ready - no entries found")
		return false
	end
	
	debug_log("oil buffer is ready")
	return true
end

-- Debounced refresh function to prevent excessive redraws
local function debounced_refresh(source)
	source = source or "unknown"
	debug_log("debounced_refresh called from: " .. source)

	-- Check cooldown period to prevent rapid-fire refreshes
	local current_time = vim.loop.now()
	if current_time - last_refresh_time < MIN_REFRESH_INTERVAL then
		debug_log("skipping refresh - within cooldown period")
		return
	end

	if refresh_timer then
		debug_log("stopping existing timer")
		vim.fn.timer_stop(refresh_timer)
	end

	refresh_timer = vim.fn.timer_start(DEBOUNCE_MS, function()
		refresh_timer = nil
		last_refresh_time = vim.loop.now()
		debug_log("timer executing refresh from: " .. source)
		
		-- Only refresh if oil buffer is ready
		if is_oil_buffer_ready() then
			apply_git_highlights()
		else
			debug_log("skipping refresh - oil buffer not ready")
		end
	end)
end

-- Retry refresh with exponential backoff for race conditions
local function retry_refresh(source, attempt)
	attempt = attempt or 1
	local max_attempts = 5
	local base_delay = 50
	
	if attempt > max_attempts then
		debug_log("retry_refresh: max attempts reached for " .. source)
		return
	end
	
	debug_log("retry_refresh: attempt " .. attempt .. " for " .. source)
	
	if is_oil_buffer_ready() then
		debug_log("retry_refresh: oil ready, applying highlights")
		apply_git_highlights()
	else
		-- Exponential backoff: 50ms, 100ms, 200ms, 400ms, 800ms
		local delay = base_delay * (2 ^ (attempt - 1))
		debug_log("retry_refresh: oil not ready, retrying in " .. delay .. "ms")
		
		vim.defer_fn(function()
			if vim.bo.filetype == "oil" then
				retry_refresh(source, attempt + 1)
			end
		end, delay)
	end
end

-- Stop periodic refresh timer
local function stop_periodic_refresh()
	if periodic_timer then
		debug_log("stopping periodic refresh timer")
		vim.fn.timer_stop(periodic_timer)
		periodic_timer = nil
	end
end

-- Start periodic refresh timer for external changes
local function start_periodic_refresh()
	if periodic_timer or not PERIODIC_REFRESH_MS then
		return -- Already running or disabled
	end

	debug_log("starting periodic refresh timer")
	periodic_timer = vim.fn.timer_start(PERIODIC_REFRESH_MS, function()
		if vim.bo.filetype == "oil" then
			debug_log("periodic refresh triggered")
			-- Only refresh if git status actually changed
			if check_git_changes_only() then
				debounced_refresh("periodic")
			end
		else
			debug_log("stopping periodic timer - not in oil buffer")
			stop_periodic_refresh()
		end
	end, { ["repeat"] = -1 }) -- Repeat indefinitely
end

local function setup_autocmds()
	local group = vim.api.nvim_create_augroup("OilGitStatus", { clear = true })

	-- Initial refresh when entering oil buffer
	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		pattern = "oil://*",
		callback = function()
			debounced_refresh("BufEnter")
			start_periodic_refresh()
		end,
	})

	-- Also trigger on any buffer with oil filetype (catches nvim . case)
	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		callback = function()
			if vim.bo.filetype == "oil" then
				-- Use retry logic for initial load to handle race conditions
				retry_refresh("BufEnter-oil-filetype")
				start_periodic_refresh()
			end
		end,
	})

	-- Clear highlights when leaving oil buffers
	vim.api.nvim_create_autocmd("BufLeave", {
		group = group,
		pattern = "oil://*",
		callback = function()
			debug_log("BufLeave - clearing highlights and timers")
			if refresh_timer then
				vim.fn.timer_stop(refresh_timer)
				refresh_timer = nil
			end
			stop_periodic_refresh()
			clear_highlights()
		end,
	})

	-- Also handle leaving any oil filetype buffer
	vim.api.nvim_create_autocmd("BufLeave", {
		group = group,
		callback = function()
			if vim.bo.filetype == "oil" then
				debug_log("BufLeave oil filetype - clearing highlights and timers")
				if refresh_timer then
					vim.fn.timer_stop(refresh_timer)
					refresh_timer = nil
				end
				stop_periodic_refresh()
				clear_highlights()
			end
		end,
	})

	-- Refresh when oil buffer content changes (file operations)
	vim.api.nvim_create_autocmd({ "BufWritePost", "TextChanged" }, {
		group = group,
		pattern = "oil://*",
		callback = function(args)
			debounced_refresh("BufWritePost/TextChanged:" .. args.event)
		end,
	})

	-- Listen for when oil buffer content is actually loaded (catches race conditions)
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
		group = group,
		callback = function(args)
			if vim.bo.filetype == "oil" then
				debug_log("BufReadPost/BufWinEnter - oil content loaded, triggering retry refresh")
				-- Small delay to ensure oil has processed the content
				vim.defer_fn(function()
					if vim.bo.filetype == "oil" then
						retry_refresh("BufReadPost/BufWinEnter:" .. args.event)
					end
				end, 25)
			end
		end,
	})

	-- Focus events (consolidated to reduce redundancy)
	vim.api.nvim_create_autocmd({ "FocusGained", "WinEnter" }, {
		group = group,
		pattern = "oil://*",
		callback = function(args)
			debounced_refresh("Focus:" .. args.event)
		end,
	})

	-- Terminal events (for when lazygit closes)
	vim.api.nvim_create_autocmd("TermClose", {
		group = group,
		callback = function()
			debug_log("TermClose event")
			-- Use a longer delay for terminal close to avoid conflicts
			vim.defer_fn(function()
				if vim.bo.filetype == "oil" then
					debounced_refresh("TermClose")
				end
			end, 100)
		end,
	})

	-- Git-related user events (removed GitSignsUpdate to prevent infinite loops)
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = { "FugitiveChanged", "LazyGitClosed" },
		callback = function(args)
			if vim.bo.filetype == "oil" then
				debounced_refresh("User:" .. args.match)
			end
		end,
	})
end

-- Track if plugin has been initialized
local initialized = false

local function initialize()
	if initialized then
		return
	end

	-- Clean up any existing timers from previous initialization
	if refresh_timer then
		vim.fn.timer_stop(refresh_timer)
		refresh_timer = nil
	end
	if periodic_timer then
		vim.fn.timer_stop(periodic_timer)
		periodic_timer = nil
	end

	setup_highlights()
	setup_autocmds()
	initialized = true
end

function M.setup(opts)
	opts = opts or {}

	-- Merge user highlights with defaults (only affects fallbacks)
	if opts.highlights then
		default_highlights = vim.tbl_extend("force", default_highlights, opts.highlights)
	end

	-- Allow enabling periodic refresh (disabled by default due to cursor blinking)
	if opts.periodic_refresh_ms then
		PERIODIC_REFRESH_MS = opts.periodic_refresh_ms
	end

	-- Legacy option for explicit disabling
	if opts.disable_periodic_refresh then
		PERIODIC_REFRESH_MS = nil
	end

	-- Allow enabling debug logging
	if opts.debug then
		DEBUG = true
	end

	initialize()
	
	-- If we're already in an oil buffer when setup is called (nvim . case),
	-- use retry logic to handle race conditions
	vim.defer_fn(function()
		if vim.bo.filetype == "oil" then
			debug_log("Setup - already in oil buffer, triggering retry refresh")
			retry_refresh("setup-existing-oil-buffer")
		end
	end, 100)
end

-- Auto-initialize when oil buffer is entered (if not already done)
vim.api.nvim_create_autocmd("FileType", {
	pattern = "oil",
	callback = function()
		initialize()
		-- Use retry logic to handle race conditions on initial load
		vim.defer_fn(function()
			if vim.bo.filetype == "oil" then
				debug_log("FileType oil - triggering retry refresh")
				retry_refresh("FileType-oil-delayed")
			end
		end, 50)
	end,
	group = vim.api.nvim_create_augroup("OilGitAutoInit", { clear = true }),
})

-- Manual refresh function (debounced)
function M.refresh()
	debounced_refresh("manual")
end

-- Force immediate git status update (bypasses debouncing and cooldowns)
function M.force_update()
	debug_log("force_update called - bypassing all debouncing")

	-- Cancel any pending timers
	if refresh_timer then
		vim.fn.timer_stop(refresh_timer)
		refresh_timer = nil
	end

	-- Reset cooldown to allow immediate refresh
	last_refresh_time = 0

	-- Clear cache to force refresh
	last_refresh_state = { dir = nil, git_status_hash = nil, buffer_lines_hash = nil }

	-- Apply highlights immediately
	apply_git_highlights()
end

return M
