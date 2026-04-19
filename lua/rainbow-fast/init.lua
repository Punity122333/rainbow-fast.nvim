-- lua/rainbow-fast/init.lua

local M = {}

local api = vim.api
local uv  = vim.uv or vim.loop

local ns          = api.nvim_create_namespace("rainbow_fast")
local ns_kw       = api.nvim_create_namespace("rainbow_fast_kw")
local query_cache = {}   -- [lang] -> ts bracket query | false
local kw_cache    = {}   -- [lang] -> ts keyword query | false
local win_timers  = {}   -- [winid] -> uv timer

-- ─────────────────────────────────────────────────────────────────────────────
-- Config
-- ─────────────────────────────────────────────────────────────────────────────

M.config = {
  colors = {
    "#E07A96",  -- red      (slightly darker pastel)
    "#FFAB76",  -- peach
    "#85AEFF",  -- blue
    "#C77DFF",  -- purple
    "#E8873A",  -- orange
  },
  debounce_ms       = 40,
  lookahead         = 10,
  brackets_enabled  = true,   -- enable bracket rainbow highlighting
  keywords_enabled  = true,   -- enable keyword depth highlighting

  -- Whitelist of filetypes where rainbow brackets are enabled.
  -- Only these will be highlighted; everything else is ignored.
  filetypes = {
    -- Web
    "html", "css", "scss", "sass", "less",
    "javascript", "javascriptreact", "typescript", "typescriptreact",
    "vue", "svelte", "astro", "htmx",
    -- Systems
    "c", "cpp", "objc", "objcpp", "cuda",
    "rust", "go", "zig", "d", "nim",
    -- JVM
    "java", "kotlin", "scala", "groovy", "clojure",
    -- Scripting
    "python", "ruby", "perl", "lua", "php",
    "bash", "sh", "zsh", "fish", "tcl",
    -- Functional
    "haskell", "elm", "elixir", "erlang", "ocaml",
    "fsharp", "purescript", "gleam", "racket", "scheme", "lisp",
    -- Data / config
    "json", "jsonc", "json5", "yaml", "toml", "xml",
    "graphql", "proto", "thrift", "avro",
    -- Query / DB
    "sql", "mysql", "plsql", "sqlite",
    -- Shell / infra
    "dockerfile", "terraform", "hcl", "nix",
    "puppet", "ansible",
    -- Scientific
    "r", "julia", "matlab", "octave", "fortran",
    -- Mobile
    "swift", "dart",
    -- .NET
    "cs", "vb",
    -- Other popular
    "zig", "odin", "v", "crystal", "hack",
    "pony", "chapel", "cobol", "ada",
    "pascal", "delphi",
    -- Templating
    "jinja", "jinja2", "twig", "liquid", "mustache", "handlebars",
    -- Markup with logic
    "mdx", "rst",
    -- Config-adjacent
    "ini", "cmake", "make", "meson",
    -- Misc langs people actually use
    "vim", "viml", "fennel", "janet", "hy",
    "coffeescript", "livescript",
    "solidity", "vyper",
    "latex", "tex",
    "nasm", "asm",
  },

  -- Per-language keyword highlighting.
  -- Each entry needs:
  --   query  : treesitter query string capturing keyword tokens as @kw
  --   blocks : set of TS node types that count as one level of nesting depth
  -- Add entries here to enable keyword highlighting for other languages.
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
        if_statement          = true,
        for_statement         = true,
        while_statement       = true,
        repeat_statement      = true,
        do_statement          = true,
        function_definition   = true,
        function_declaration  = true,
        local_function        = true,
      },
    },

    python = {
      query = [[
        "def"     @kw
        "class"   @kw
        "if"      @kw
        "elif"    @kw
        "else"    @kw
        "for"     @kw
        "while"   @kw
        "with"    @kw
        "try"     @kw
        "except"  @kw
        "finally" @kw
        "return"  @kw
        "async"   @kw
        "await"   @kw
        "lambda"  @kw
        "match"   @kw
        "case"    @kw
      ]],
      blocks = {
        function_definition  = true,
        class_definition     = true,
        if_statement         = true,
        for_statement        = true,
        while_statement      = true,
        with_statement       = true,
        try_statement        = true,
        match_statement      = true,
        decorated_definition = true,
      },
    },

    ruby = {
      query = [[
        "def"    @kw
        "class"  @kw
        "module" @kw
        "if"     @kw
        "elsif"  @kw
        "else"   @kw
        "unless" @kw
        "then"   @kw
        "end"    @kw
        "for"    @kw
        "while"  @kw
        "until"  @kw
        "do"     @kw
        "begin"  @kw
        "rescue" @kw
        "ensure" @kw
        "return" @kw
      ]],
      blocks = {
        method           = true,
        class            = true,
        module           = true,
        block            = true,
        do_block         = true,
        ["if"]           = true,
        ["unless"]       = true,
        ["while"]        = true,
        ["until"]        = true,
        ["for"]          = true,
        ["begin"]        = true,
        ["rescue"]       = true,
      },
    },

    bash = {
      query = [[
        "if"       @kw
        "then"     @kw
        "elif"     @kw
        "else"     @kw
        "fi"       @kw
        "for"      @kw
        "while"    @kw
        "until"    @kw
        "do"       @kw
        "done"     @kw
        "case"     @kw
        "esac"     @kw
        "function" @kw
        "in"       @kw
      ]],
      blocks = {
        if_statement       = true,
        for_statement      = true,
        while_statement    = true,
        case_statement     = true,
        function_definition = true,
        subshell           = true,
        compound_statement = true,
      },
    },

    vim = {
      query = [[
        "if"        @kw
        "elseif"    @kw
        "else"      @kw
        "endif"     @kw
        "for"       @kw
        "endfor"    @kw
        "while"     @kw
        "endwhile"  @kw
        "function"  @kw
        "endfunction" @kw
        "try"       @kw
        "catch"     @kw
        "finally"   @kw
        "endtry"    @kw
        "return"    @kw
      ]],
      blocks = {
        if_statement       = true,
        for_loop           = true,
        while_loop         = true,
        function_definition = true,
        try_statement      = true,
      },
    },

    elixir = {
      query = [[
        "def"       @kw
        "defp"      @kw
        "defmodule" @kw
        "defstruct" @kw
        "defmacro"  @kw
        "do"        @kw
        "end"       @kw
        "if"        @kw
        "else"      @kw
        "cond"      @kw
        "case"      @kw
        "fn"        @kw
        "with"      @kw
        "for"       @kw
        "receive"   @kw
        "try"       @kw
        "rescue"    @kw
        "catch"     @kw
        "after"     @kw
      ]],
      blocks = {
        call          = true,
        do_block      = true,
        stab_clause   = true,
        anonymous_function = true,
      },
    },

    julia = {
      query = [[
        "if"       @kw
        "elseif"   @kw
        "else"     @kw
        "end"      @kw
        "for"      @kw
        "while"    @kw
        "function" @kw
        "return"   @kw
        "begin"    @kw
        "do"       @kw
        "try"      @kw
        "catch"    @kw
        "finally"  @kw
        "struct"   @kw
        "module"   @kw
        "let"      @kw
        "macro"    @kw
        "in"       @kw
      ]],
      blocks = {
        if_statement       = true,
        for_statement      = true,
        while_statement    = true,
        function_definition = true,
        begin_statement    = true,
        try_statement      = true,
        struct_definition  = true,
        module_definition  = true,
        let_statement      = true,
      },
    },

    nim = {
      query = [[
        "if"       @kw
        "elif"     @kw
        "else"     @kw
        "for"      @kw
        "while"    @kw
        "proc"     @kw
        "func"     @kw
        "method"   @kw
        "iterator" @kw
        "template" @kw
        "macro"    @kw
        "type"     @kw
        "block"    @kw
        "when"     @kw
        "case"     @kw
        "of"       @kw
        "try"      @kw
        "except"   @kw
        "finally"  @kw
        "return"   @kw
      ]],
      blocks = {
        if_statement       = true,
        for_statement      = true,
        while_statement    = true,
        proc_declaration   = true,
        func_declaration   = true,
        type_section       = true,
        block_statement    = true,
        try_statement      = true,
      },
    },

    ocaml = {
      query = [[
        "let"      @kw
        "in"       @kw
        "if"       @kw
        "then"     @kw
        "else"     @kw
        "match"    @kw
        "with"     @kw
        "fun"      @kw
        "function" @kw
        "begin"    @kw
        "end"      @kw
        "type"     @kw
        "module"   @kw
        "struct"   @kw
        "sig"      @kw
        "for"      @kw
        "while"    @kw
        "do"       @kw
        "done"     @kw
      ]],
      blocks = {
        let_binding        = true,
        if_expression      = true,
        match_expression   = true,
        fun_expression     = true,
        for_expression     = true,
        while_expression   = true,
        structure          = true,
        module_binding     = true,
        type_definition    = true,
      },
    },
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
  if cached ~= nil then return cached end

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

local OPEN_BYTES  = { [40] = true, [91] = true, [123] = true }  -- ( [ {
local CLOSE_BYTES = { [41] = true, [93] = true, [125] = true }  -- ) ] }

local function render_raw(bufnr, top, bot)
  local ok, lines = pcall(api.nvim_buf_get_lines, bufnr, 0, bot, false)
  if not ok then return end

  local depth = 0
  local marks = {}

  for i, line in ipairs(lines) do
    local row   = i - 1
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
      end_col  = m[2] + 1,
      hl_group = m[3],
      priority = 200,
      strict   = false,
    })
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- TS render path
-- ─────────────────────────────────────────────────────────────────────────────

local OPEN_TYPES = { ["("] = true, ["["] = true, ["{"] = true }

-- ─────────────────────────────────────────────────────────────────────────────
-- Keyword highlighting (per-language, AST-depth coloured)
-- ─────────────────────────────────────────────────────────────────────────────

local function get_kw_query(lang)
  local cached = kw_cache[lang]
  if cached ~= nil then return cached end

  local cfg = M.config.keyword_langs[lang]
  if not cfg then
    kw_cache[lang] = false
    return false
  end

  local ok, q = pcall(vim.treesitter.query.parse, lang, cfg.query)
  kw_cache[lang] = ok and q or false
  return kw_cache[lang]
end

-- Count how many block-container ancestors a node has.
-- This gives the nesting depth for keyword colouring.
local function kw_depth(node, blocks)
  local depth = 0
  local p = node:parent()
  while p do
    if blocks[p:type()] then depth = depth + 1 end
    p = p:parent()
  end
  return depth
end

local function render_keywords(bufnr, parser, top, bot)
  local lang  = parser:lang()
  local query = get_kw_query(lang)
  if not query then return end

  local cfg    = M.config.keyword_langs[lang]
  local blocks = cfg.blocks

  local ok_t, trees = pcall(function() return parser:parse() end)
  if not ok_t or not trees or not trees[1] then return end

  local root  = trees[1]:root()
  local marks = {}

  for _, node in query:iter_captures(root, bufnr, top, bot) do
    local sr, sc = node:start()
    local er, ec = node:end_()
    if sr >= top and sr < bot then
      local d = kw_depth(node, blocks)
      -- depth 0 = top-level, still colour it (as depth 1 so it's not invisible)
      marks[#marks + 1] = { sr, sc, er, ec, hl(math.max(1, d)) }
    end
  end

  api.nvim_buf_clear_namespace(bufnr, ns_kw, top, bot)
  for _, m in ipairs(marks) do
    pcall(api.nvim_buf_set_extmark, bufnr, ns_kw, m[1], m[2], {
      end_row  = m[3],
      end_col  = m[4],
      hl_group = m[5],
      priority = 190,   -- just below bracket priority so brackets win on overlap
      strict   = false,
    })
  end
end

-- Node types that count as "string-like" containers.
-- Brackets inside any of these are skipped.
local STRING_CONTAINERS = {
  string          = true,
  string_content  = true,
  template_string = true,
  raw_string      = true,
  interpreted_string_literal = true,  -- Go
  char_literal    = true,
  comment         = true,
  line_comment    = true,
  block_comment   = true,
  doc_comment     = true,
}

-- Walk up the ancestor chain; return true if the node lives inside a string
-- or comment. Stops at the root so it's O(depth) — typically 5–15 hops.
local function in_string(node)
  local p = node:parent()
  while p do
    if STRING_CONTAINERS[p:type()] then return true end
    p = p:parent()
  end
  return false
end

local function render_ts(bufnr, top, bot)
  local ok_p, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok_p or not parser then return false end

  local ok_t, trees = pcall(function() return parser:parse() end)
  if not ok_t or not trees or not trees[1] then return false end

  local lang  = parser:lang()
  local query = get_query(lang)
  if not query then return false end

  local root   = trees[1]:root()
  local depth  = 0
  local marks  = {}
  local n_caps = 0

  for _, node in query:iter_captures(root, bufnr, 0, bot) do
    local sr, sc = node:start()
    local typ    = node:type()
    n_caps       = n_caps + 1

    -- Skip brackets that live inside strings or comments.
    if in_string(node) then goto continue end

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
  if n_caps == 0 then return false end

  api.nvim_buf_clear_namespace(bufnr, ns, top, bot)
  for _, m in ipairs(marks) do
    pcall(api.nvim_buf_set_extmark, bufnr, ns, m[1], m[2], {
      end_col  = m[2] + 1,
      hl_group = m[3],
      priority = 200,
      strict   = false,
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
  if not api.nvim_win_is_valid(winid) then return end
  if not api.nvim_buf_is_valid(bufnr)  then return end

  if not ft_enabled[vim.bo[bufnr].filetype] then return end

  local la  = M.config.lookahead
  local top = math.max(0, vim.fn.line("w0", winid) - 1 - la)
  local bot = vim.fn.line("w$", winid) + la

  if M.config.brackets_enabled then
    local ok, used_ts = pcall(render_ts, bufnr, top, bot)
    if not ok or not used_ts then
      pcall(render_raw, bufnr, top, bot)
    end
  end

  -- Keyword highlighting (only possible with TS).
  if M.config.keywords_enabled then
    local ok_p, parser = pcall(vim.treesitter.get_parser, bufnr)
    if ok_p and parser then
      pcall(render_keywords, bufnr, parser, top, bot)
    end
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
  if not t then return end
  win_timers[winid] = t
  t:start(delay_ms, 0, vim.schedule_wrap(function()
    if not t:is_closing() then t:close() end
    win_timers[winid] = nil
    render(winid, bufnr)
  end))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

function M.refresh()
  local winid = api.nvim_get_current_win()
  local bufnr = api.nvim_win_get_buf(winid)
  render(winid, bufnr)
end

local function clear_brackets()
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(b) then
      api.nvim_buf_clear_namespace(b, ns, 0, -1)
    end
  end
end

local function clear_keywords()
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(b) then
      api.nvim_buf_clear_namespace(b, ns_kw, 0, -1)
    end
  end
end

function M.clear()
  clear_brackets()
  clear_keywords()
end

--- Toggle all highlighting on/off.
function M.toggle()
  local on = not (M.config.brackets_enabled or M.config.keywords_enabled)
  M.config.brackets_enabled = on
  M.config.keywords_enabled = on
  if on then M.refresh() else M.clear() end
end

--- Toggle only bracket highlighting.
function M.toggle_brackets()
  M.config.brackets_enabled = not M.config.brackets_enabled
  if M.config.brackets_enabled then
    M.refresh()
  else
    clear_brackets()
  end
end

--- Toggle only keyword highlighting.
function M.toggle_keywords()
  M.config.keywords_enabled = not M.config.keywords_enabled
  if M.config.keywords_enabled then
    M.refresh()
  else
    clear_keywords()
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
    group    = aug,
    callback = setup_hl,
  })

  -- Immediate render on these events.
  api.nvim_create_autocmd({ "BufEnter", "BufRead", "BufWinEnter", "BufNewFile", "FileType", "InsertLeave" }, {
    group = aug,
    callback = function()
      if not (M.config.brackets_enabled or M.config.keywords_enabled) then return end
      local winid = api.nvim_get_current_win()
      local bufnr = api.nvim_win_get_buf(winid)
      vim.schedule(function() render(winid, bufnr) end)
    end,
  })

  -- Debounced render for high-frequency events.
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "WinScrolled", "WinResized" }, {
    group = aug,
    callback = function()
      if not (M.config.brackets_enabled or M.config.keywords_enabled) then return end
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

