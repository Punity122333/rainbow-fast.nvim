-- lua/rainbow-fast/init.lua

local M = {}

local api = vim.api
local uv = vim.uv or vim.loop

local ns = api.nvim_create_namespace("rainbow_fast")
local ns_kw = api.nvim_create_namespace("rainbow_fast_kw")
local query_cache = {} -- [lang] -> ts bracket query | false
local kw_cache = {} -- [lang] -> ts keyword query | false
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
	enable_keywords = true, -- Toggleable keyword highlighting

	-- Whitelist of filetypes where rainbow brackets are enabled.
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

	keyword_langs = {
		lua = {
			query = [[
        "if"       @kw
        "elseif"   @kw
        "else"     @kw
        "then"     @kw
        "end"      @kw
        "for"      @kw
        "do"       @kw
        "while"    @kw
        "repeat"   @kw
        "until"    @kw
        "function" @kw
        "return"   @kw
        "local"    @kw
        "in"       @kw
      ]],
			blocks = {
				if_statement = true,
				for_statement = true,
				while_statement = true,
				repeat_statement = true,
				do_statement = true,
				function_definition = true,
				function_declaration = true,
				local_function = true,
				method_index_expression = true,
			},
		},
	},
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Highlight groups
-- ─────────────────────────────────────────────────────────────────────────────

local function setup_hl()
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
-- Raw Lua fallback
-- ─────────────────────────────────────────────────────────────────────────────

local OPEN_BYTES = { [40] = true, [91] = true, [123] = true }
local CLOSE_BYTES = { [41] = true, [93] = true, [125] = true }

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

local function get_kw_query(lang)
	local cached = kw_cache[lang]
	if cached ~= nil then
		return cached
	end

	local cfg = M.config.keyword_langs[lang]
	if not cfg then
		kw_cache[lang] = false
		return false
	end

	local ok, q = pcall(vim.treesitter.query.parse, lang, cfg.query)
	kw_cache[lang] = ok and q or false
	return kw_cache[lang]
end

local function kw_depth(node, blocks)
	local depth = 0
	local p = node:parent()
	while p do
		if blocks[p:type()] then
			depth = depth + 1
		end
		p = p:parent()
	end
	return depth
end

local function render_keywords(bufnr, parser, top, bot)
	local lang = parser:lang()
	local query = get_kw_query(lang)
	if not query then
		return
	end

	local cfg = M.config.keyword_langs[lang]
	local blocks = cfg.blocks

	local ok_t, trees = pcall(function()
		return parser:parse()
	end)
	if not ok_t or not trees or not trees[1] then
		return
	end

	local root = trees[1]:root()
	local marks = {}

	for _, node in query:iter_captures(root, bufnr, top, bot) do
		local sr, sc = node:start()
		local er, ec = node:end_()
		if sr >= top and sr < bot then
			local d = kw_depth(node, blocks)
			marks[#marks + 1] = { sr, sc, er, ec, hl(math.max(1, d)) }
		end
	end

	api.nvim_buf_clear_namespace(bufnr, ns_kw, top, bot)
	for _, m in ipairs(marks) do
		pcall(api.nvim_buf_set_extmark, bufnr, ns_kw, m[1], m[2], {
			end_row = m[3],
			end_col = m[4],
			hl_group = m[5],
			priority = 190,
			strict = false,
		})
	end
end

local STRING_CONTAINERS = {
	string = true,
	string_content = true,
	template_string = true,
	raw_string = true,
	interpreted_string_literal = true,
	char_literal = true,
	comment = true,
	line_comment = true,
	block_comment = true,
	doc_comment = true,
}

local function in_string(node)
	local p = node:parent()
	while p do
		if STRING_CONTAINERS[p:type()] then
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

	-- Keyword highlighting logic
	if M._keywords_enabled then
		local ok_p, parser = pcall(vim.treesitter.get_parser, bufnr)
		if ok_p and parser then
			pcall(render_keywords, bufnr, parser, top, bot)
		end
	else
		-- Clear keyword namespace in viewport if it's disabled
		api.nvim_buf_clear_namespace(bufnr, ns_kw, top, bot)
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
			api.nvim_buf_clear_namespace(b, ns_kw, 0, -1)
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

M._keywords_enabled = true
function M.toggle_keywords()
	M._keywords_enabled = not M._keywords_enabled
	if M._keywords_enabled then
		M.refresh()
	else
		-- Just clear the keyword namespace globally when turned off
		for _, b in ipairs(api.nvim_list_bufs()) do
			if api.nvim_buf_is_valid(b) then
				api.nvim_buf_clear_namespace(b, ns_kw, 0, -1)
			end
		end
	end
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	-- Initialize keyword state based on config
	M._keywords_enabled = M.config.enable_keywords

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
