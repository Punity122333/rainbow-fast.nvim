-- lua/rainbow-fast/init.lua

local M = {}

local api = vim.api
local uv = vim.uv or vim.loop

local ns = api.nvim_create_namespace("rainbow_fast")
local query_cache = {} -- [lang] -> ts query | false
local win_timers = {} -- [winid] -> uv timer

-- ─────────────────────────────────────────────────────────────────────────────
-- Config
-- ─────────────────────────────────────────────────────────────────────────────

M.config = {
	colors = {
		"#E07A96", -- red      (slightly darker pastel)
		"#FFAB76", -- peach
		"#85AEFF", -- blue
		"#C77DFF", -- purple
		"#E8873A", -- orange
	},
	debounce_ms = 80,
	lookahead = 10,

	-- Whitelist of filetypes where rainbow brackets are enabled.
	-- Only these will be highlighted; everything else is ignored.
	filetypes = {
		-- Web
		"html",
		"css",
		"scss",
		"sass",
		"less",
		"javascript",
		"javascriptreact",
		"typescript",
		"typescriptreact",
		"vue",
		"svelte",
		"astro",
		"htmx",
		-- Systems
		"c",
		"cpp",
		"objc",
		"objcpp",
		"cuda",
		"rust",
		"go",
		"zig",
		"d",
		"nim",
		-- JVM
		"java",
		"kotlin",
		"scala",
		"groovy",
		"clojure",
		-- Scripting
		"python",
		"ruby",
		"perl",
		"lua",
		"php",
		"bash",
		"sh",
		"zsh",
		"fish",
		"tcl",
		-- Functional
		"haskell",
		"elm",
		"elixir",
		"erlang",
		"ocaml",
		"fsharp",
		"purescript",
		"gleam",
		"racket",
		"scheme",
		"lisp",
		-- Data / config
		"json",
		"jsonc",
		"json5",
		"yaml",
		"toml",
		"xml",
		"graphql",
		"proto",
		"thrift",
		"avro",
		-- Query / DB
		"sql",
		"mysql",
		"plsql",
		"sqlite",
		-- Shell / infra
		"dockerfile",
		"terraform",
		"hcl",
		"nix",
		"puppet",
		"ansible",
		-- Scientific
		"r",
		"julia",
		"matlab",
		"octave",
		"fortran",
		-- Mobile
		"swift",
		"dart",
		-- .NET
		"cs",
		"vb",
		-- Other popular
		"zig",
		"odin",
		"v",
		"crystal",
		"hack",
		"pony",
		"chapel",
		"cobol",
		"ada",
		"pascal",
		"delphi",
		-- Templating
		"jinja",
		"jinja2",
		"twig",
		"liquid",
		"mustache",
		"handlebars",
		-- Markup with logic
		"mdx",
		"rst",
		-- Config-adjacent
		"ini",
		"cmake",
		"make",
		"meson",
		-- Misc langs people actually use
		"vim",
		"viml",
		"fennel",
		"janet",
		"hy",
		"coffeescript",
		"livescript",
		"solidity",
		"vyper",
		"latex",
		"tex",
		"nasm",
		"asm",
	},
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Highlight groups
-- ─────────────────────────────────────────────────────────────────────────────

local function setup_hl()
	-- Clear up to 10 groups first so stale colours from a previous load
	-- (e.g. old RainbowFast3 = green) don't bleed through.
	for i = 1, 10 do
		pcall(api.nvim_set_hl, 0, "RainbowFast" .. i, {})
	end
	for i, hex in ipairs(M.config.colors) do
		api.nvim_set_hl(0, "RainbowFast" .. i, { fg = hex, bold = true })
	end
end

local function hl(depth)
	local n = #M.config.colors
	return "RainbowFast" .. ((depth - 1) % n + 1)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- TS query — compiled once per language
-- ─────────────────────────────────────────────────────────────────────────────

local QUERIES = {
	'["(" ")" "[" "]" "{" "}"] @bracket',
	'["(" ")"] @bracket',
}

local function get_query(lang)
	local cached = query_cache[lang]
	if cached ~= nil then
		return cached
	end

	for _, qstr in ipairs(QUERIES) do
		local ok, q = pcall(vim.treesitter.query.parse, lang, qstr)
		if ok and q then
			query_cache[lang] = q
			return q
		end
	end

	query_cache[lang] = false
	return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Raw Lua fallback (always works, no string/comment awareness)
-- ─────────────────────────────────────────────────────────────────────────────

local OPEN_BYTES = { [40] = true, [91] = true, [123] = true } -- ( [ {
local CLOSE_BYTES = { [41] = true, [93] = true, [125] = true } -- ) ] }

local function render_raw(bufnr, top, bot)
	local ok, lines = pcall(api.nvim_buf_get_lines, bufnr, 0, bot, false)
	if not ok then
		return
	end

	local depth = 0
	local marks = {}

	for i, line in ipairs(lines) do
		local row = i - 1
		local in_vp = row >= top

		for col = 1, #line do
			local b = line:byte(col)
			if OPEN_BYTES[b] then
				depth = depth + 1
				if in_vp then
					marks[#marks + 1] = { row, col - 1, hl(depth) }
				end
			elseif CLOSE_BYTES[b] then
				if depth > 0 then
					if in_vp then
						marks[#marks + 1] = { row, col - 1, hl(depth) }
					end
					depth = depth - 1
				end
			end
		end
	end

	api.nvim_buf_clear_namespace(bufnr, ns, top, bot)
	for _, m in ipairs(marks) do
		pcall(api.nvim_buf_set_extmark, bufnr, ns, m[1], m[2], {
			end_col = m[2] + 1,
			hl_group = m[3],
			priority = 200,
			strict = false,
		})
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- TS render path
-- ─────────────────────────────────────────────────────────────────────────────

local OPEN_TYPES = { ["("] = true, ["["] = true, ["{"] = true }

-- Node types that count as "string-like" containers.
-- Brackets inside any of these are skipped.
local STRING_CONTAINERS = {
	string = true,
	string_content = true,
	template_string = true,
	raw_string = true,
	interpreted_string_literal = true, -- Go
	char_literal = true,
	comment = true,
	line_comment = true,
	block_comment = true,
	doc_comment = true,
	String = true,
	String_content = true,
	Template_string = true,
	Raw_string = true,
	Interpreted_string_literal = true, -- Go
	Char_literal = true,
	Comment = true,
	Line_comment = true,
	Block_comment = true,
	Doc_comment = true,
	STRING = true,
	STRING_CONTENT = true,
	TEMPLATE_STRING = true,
	RAW_STRING = true,
	INTERPRETED_STRING_LITERAL = true, -- Go
	CHAR_LITERAL = true,
	COMMENT = true,
	LINE_COMMENT = true,
	BLOCK_COMMENT = true,
	DOC_COMMENT = true,
	String_Content = true,
	Template_String = true,
	Raw_String = true,
	Interpreted_String_Literal = true, -- Go
	Char_Literal = true,
	Line_Comment = true,
	Block_Comment = true,
	Doc_Comment = true,
}

-- Walk up the ancestor chain; return true if the node lives inside a string
-- or comment. Stops at the root so it's O(depth) — typically 5–15 hops.

local function in_string(node)
	local p = node:parent()
	while p do
		local node_type = p:type():lower()
		if STRING_CONTAINERS[node_type] then
			return true
		end
		p = p:parent()
	end
	return false
end

local function render_ts(bufnr, top, bot)
	local ok_p, parser = pcall(vim.treesitter.get_parser, bufnr)
	if not ok_p or not parser then
		return false
	end

	local ok_t, trees = pcall(function()
		return parser:parse()
	end)
	if not ok_t or not trees or not trees[1] then
		return false
	end

	local lang = parser:lang()
	local query = get_query(lang)
	if not query then
		return false
	end

	local root = trees[1]:root()
	local depth = 0
	local marks = {}
	local n_caps = 0

	for _, node in query:iter_captures(root, bufnr, 0, bot) do
		local sr, sc = node:start()
		local typ = node:type()
		n_caps = n_caps + 1

		-- Skip brackets that live inside strings or comments.
		if in_string(node) then
			goto continue
		end

		if OPEN_TYPES[typ] then
			depth = depth + 1
			if sr >= top then
				marks[#marks + 1] = { sr, sc, hl(depth) }
			end
		else
			if depth > 0 then
				if sr >= top then
					marks[#marks + 1] = { sr, sc, hl(depth) }
				end
				depth = depth - 1
			end
		end

		::continue::
	end

	-- Zero captures = grammar doesn't surface bracket nodes; use raw fallback.
	if n_caps == 0 then
		return false
	end

	api.nvim_buf_clear_namespace(bufnr, ns, top, bot)
	for _, m in ipairs(marks) do
		pcall(api.nvim_buf_set_extmark, bufnr, ns, m[1], m[2], {
			end_col = m[2] + 1,
			hl_group = m[3],
			priority = 200,
			strict = false,
		})
	end
	return true
end

-- Fast O(1) filetype lookup built from config.filetypes on setup()
local ft_enabled = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Main render entry-point
-- ─────────────────────────────────────────────────────────────────────────────

local function render(winid, bufnr)
	if not api.nvim_win_is_valid(winid) then
		return
	end
	if not api.nvim_buf_is_valid(bufnr) then
		return
	end

	if not ft_enabled[vim.bo[bufnr].filetype] then
		return
	end

	local la = M.config.lookahead
	local top = math.max(0, vim.fn.line("w0", winid) - 1 - la)
	local bot = vim.fn.line("w$", winid) + la

	local ok, used_ts = pcall(render_ts, bufnr, top, bot)
	if not ok or not used_ts then
		pcall(render_raw, bufnr, top, bot)
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Debounced scheduling
-- ─────────────────────────────────────────────────────────────────────────────

local function schedule(winid, bufnr, delay_ms)
	local old = win_timers[winid]
	if old and not old:is_closing() then
		old:stop()
		old:close()
	end

	local t = uv.new_timer()
	win_timers[winid] = t
	t:start(
		delay_ms,
		0,
		vim.schedule_wrap(function()
			if not t:is_closing() then
				t:close()
			end
			win_timers[winid] = nil
			render(winid, bufnr)
		end)
	)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

function M.refresh()
	local winid = api.nvim_get_current_win()
	local bufnr = api.nvim_win_get_buf(winid)
	render(winid, bufnr)
end

function M.clear()
	for _, b in ipairs(api.nvim_list_bufs()) do
		if api.nvim_buf_is_valid(b) then
			api.nvim_buf_clear_namespace(b, ns, 0, -1)
		end
	end
end

M._enabled = true
function M.toggle()
	M._enabled = not M._enabled
	if M._enabled then
		M.refresh()
	else
		M.clear()
	end
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	-- Build O(1) lookup set from whitelist.
	ft_enabled = {}
	for _, ft in ipairs(M.config.filetypes) do
		ft_enabled[ft] = true
	end

	setup_hl()

	local aug = api.nvim_create_augroup("RainbowFast", { clear = true })

	api.nvim_create_autocmd("ColorScheme", {
		group = aug,
		callback = setup_hl,
	})

	-- Immediate render on these events.
	api.nvim_create_autocmd({ "BufEnter", "BufRead", "BufWinEnter", "BufNewFile", "FileType", "InsertLeave" }, {
		group = aug,
		callback = function()
			if not M._enabled then
				return
			end
			local winid = api.nvim_get_current_win()
			local bufnr = api.nvim_win_get_buf(winid)
			vim.schedule(function()
				render(winid, bufnr)
			end)
		end,
	})

	-- Debounced render for high-frequency events.
	api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "WinScrolled", "WinResized" }, {
		group = aug,
		callback = function()
			if not M._enabled then
				return
			end
			local winid = api.nvim_get_current_win()
			local bufnr = api.nvim_win_get_buf(winid)
			schedule(winid, bufnr, M.config.debounce_ms)
		end,
	})

	-- Render all windows that are already open when setup() is called.
	-- lazy.nvim loads plugins after buffers open, so vim.schedule alone (which
	-- only renders the current window at that tick) misses splits and the case
	-- where the plugin loads after BufRead has already fired.
	vim.schedule(function()
		for _, winid in ipairs(api.nvim_list_wins()) do
			if api.nvim_win_is_valid(winid) then
				local bufnr = api.nvim_win_get_buf(winid)
				render(winid, bufnr)
			end
		end
	end)
end

return M
