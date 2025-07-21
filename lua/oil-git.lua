local M = {}

-- Default highlight colors (only used if not already defined)
local default_highlights = {
	OilGitAdded = { fg = "#a6e3a1" },
	OilGitModified = { fg = "#f9e2af" },
	OilGitRenamed = { fg = "#cba6f7" },
	OilGitUntracked = { fg = "#89b4fa" },
	OilGitIgnored = { fg = "#6c7086" },
	-- Directory highlights (slightly dimmed versions)
	OilGitDirAdded = { fg = "#a6e3a1", italic = true },
	OilGitDirModified = { fg = "#f9e2af", italic = true },
	OilGitDirRenamed = { fg = "#cba6f7", italic = true },
	OilGitDirUntracked = { fg = "#89b4fa", italic = true },
	OilGitDirIgnored = { fg = "#6c7086", italic = true },
}

-- Debouncing variables
local refresh_timer = nil
local DEBOUNCE_MS = 50
local last_refresh_time = 0
local MIN_REFRESH_INTERVAL = 200  -- Minimum 200ms between actual refreshes

-- Periodic refresh for external changes
local periodic_timer = nil
local PERIODIC_REFRESH_MS = 3000  -- 3 seconds

-- Redraw strategy for cursor blinking control
local REDRAW_STRATEGY = "gentle"  -- "gentle", "immediate", "none"

-- Cache to prevent unnecessary refreshes
local last_refresh_state = {
	dir = nil,
	git_status_hash = nil,
	buffer_lines_hash = nil,
}

-- Debug flag - configurable via setup options
local DEBUG = true

local function debug_log(msg, level)
	if DEBUG then
		vim.notify("[oil-git] " .. msg, level or vim.log.levels.INFO)
	end
end

local function setup_highlights()
	-- Only set highlight if it doesn't already exist (respects colorscheme)
	for name, opts in pairs(default_highlights) do
		if vim.fn.hlexists(name) == 0 then
			vim.api.nvim_set_hl(0, name, opts)
		end
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
	local status_priority = {
		["A"] = 4,  -- Added (highest priority)
		["M"] = 3,  -- Modified
		["R"] = 2,  -- Renamed
		["?"] = 1,  -- Untracked
		["!"] = 0,  -- Ignored (lowest priority)
	}
	
	local highest_priority = -1
	local highest_status = nil
	
	for filepath, status_code in pairs(git_status) do
		-- Check if this file is within the directory
		if filepath:sub(1, #dir_path_normalized) == dir_path_normalized then
			local first_char = status_code:sub(1, 1)
			local second_char = status_code:sub(2, 2)
			
			-- Check both staged and unstaged changes
			for _, char in ipairs({first_char, second_char}) do
				local priority = status_priority[char]
				if priority and priority > highest_priority then
					highest_priority = priority
					highest_status = char .. char  -- Convert single char to status code format
				end
			end
		end
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

-- Store match IDs to clear only our highlights
local git_match_ids = {}

local function clear_highlights()
	debug_log("*** CLEAR_HIGHLIGHTS called - CURSOR BLINK SOURCE!")
	debug_log("Match IDs to clear: " .. #git_match_ids)
	
	-- Clear only our specific git highlights
	for i, match_id in ipairs(git_match_ids) do
		debug_log("Clearing match ID: " .. match_id)
		pcall(vim.fn.matchdelete, match_id)
	end
	git_match_ids = {}

	-- Clear existing virtual text
	local ns_id = vim.api.nvim_create_namespace("oil_git_status")
	local bufnr = vim.api.nvim_get_current_buf()
	debug_log("Clearing namespace for buffer: " .. bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
	debug_log("*** CLEAR_HIGHLIGHTS completed")
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
		debug_log(string.format("should_refresh: YES (dir:%s git:%s lines:%s)", 
			tostring(dir_changed), tostring(git_changed), tostring(lines_changed)))
		
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
	
	-- Quick check: if we're in the same directory and had no git status before, skip entirely
	if last_refresh_state.dir == current_dir and 
	   last_refresh_state.git_status_hash == simple_hash({}) then
		debug_log("same directory with no previous git status - skipping entirely to prevent cursor blink")
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
	
	-- Check if refresh is actually needed
	if not should_refresh(current_dir, git_status, lines) then
		debug_log("no refresh needed - content unchanged")
		return -- Skip refresh if nothing changed
	end

	debug_log("applying highlights - content changed")
	
	-- Save cursor position to restore later
	local cursor_pos = vim.api.nvim_win_get_cursor(0)
	local view = vim.fn.winsaveview()
	
	-- Disable redraw during highlight operations
	vim.cmd('set lazyredraw')
	
	clear_highlights()

	-- Get namespace once and reuse
	local ns_id = vim.api.nvim_create_namespace("oil_git_status")

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
				-- Find the entry name in the line and highlight it
				local name_start = line:find(entry.name, 1, true)
				if name_start then
					-- For directories, include the trailing slash in the highlight
					local highlight_length = #entry.name
					if is_directory then
						-- Check if there's a trailing slash after the directory name
						local slash_pos = name_start + #entry.name
						if slash_pos <= #line and line:sub(slash_pos, slash_pos) == "/" then
							highlight_length = highlight_length + 1
						end
					end
					
					-- Highlight the entry name (and trailing slash for directories) and store match ID
					local match_id = vim.fn.matchaddpos(hl_group, { { i, name_start, highlight_length } })
					if match_id > 0 then
						table.insert(git_match_ids, match_id)
					end

					-- Add symbol as virtual text at the end of the line
					-- Use pcall to prevent errors from causing redraws
					pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, i - 1, 0, {
						virt_text = { { " " .. symbol, hl_group } },
						virt_text_pos = "eol",
						-- Add strict invalidation to prevent stale extmarks
						invalidate = true,
					})
				end
			end
		end
	end
	
	-- Restore cursor position and view
	pcall(vim.api.nvim_win_set_cursor, 0, cursor_pos)
	pcall(vim.fn.winrestview, view)
	
	-- Re-enable redraw with configurable strategy
	vim.cmd('set nolazyredraw')
	
	-- Apply redraw strategy based on configuration
	if REDRAW_STRATEGY == "immediate" then
		debug_log("*** REDRAW: immediate - WILL CAUSE CURSOR BLINK!")
		vim.cmd('redraw!')
	elseif REDRAW_STRATEGY == "gentle" then
		debug_log("*** REDRAW: gentle - scheduling redraw")
		-- Schedule redraw to next event loop to minimize cursor blinking
		vim.schedule(function()
			debug_log("*** REDRAW: gentle - executing scheduled redraw - CURSOR BLINK!")
			vim.cmd('redraw!')
		end)
	elseif REDRAW_STRATEGY == "none" then
		debug_log("*** REDRAW: none - no forced redraw")
		-- No forced redraw - let Neovim handle it naturally
		-- This may result in delayed visual updates but no cursor blinking
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
		-- Only refresh if we're still in an oil buffer
		if vim.bo.filetype == "oil" then
			apply_git_highlights()
		else
			debug_log("skipping refresh - not in oil buffer")
		end
	end)
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

	-- Refresh when oil buffer content changes (file operations)
	vim.api.nvim_create_autocmd({ "BufWritePost", "TextChanged" }, {
		group = group,
		pattern = "oil://*",
		callback = function(args)
			debounced_refresh("BufWritePost/TextChanged:" .. args.event)
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

	-- Allow customization of periodic refresh interval
	if opts.periodic_refresh_ms then
		PERIODIC_REFRESH_MS = opts.periodic_refresh_ms
	end
	
	-- Allow disabling periodic refresh entirely
	if opts.disable_periodic_refresh then
		PERIODIC_REFRESH_MS = nil
	end
	
	-- Allow enabling debug logging
	if opts.debug ~= nil then
		DEBUG = opts.debug
	end
	
	-- Allow customizing redraw strategy
	if opts.redraw_strategy then
		REDRAW_STRATEGY = opts.redraw_strategy
	end

	initialize()
end

-- Auto-initialize when oil buffer is entered (if not already done)
vim.api.nvim_create_autocmd("FileType", {
	pattern = "oil",
	callback = function()
		initialize()
	end,
	group = vim.api.nvim_create_augroup("OilGitAutoInit", { clear = true }),
})

-- Manual refresh function
function M.refresh()
	debounced_refresh("manual")
end

return M
