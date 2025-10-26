local Morph = require 'morph'
local h = Morph.h

-- morph.examples.Path {{{
--------------------------------------------------------------------------------
-- Path
-- This is a simple Path utility just for easily dealing with file-system
-- navigation. This is the simplest/lowest layer of abstraction.
--------------------------------------------------------------------------------
--- @class morph.examples.Path
--- @field _path string
local Path = {}
Path.__index = Path

--- @param path string
function Path.new(path)
  return setmetatable({ _path = vim.fs.abspath(vim.fs.normalize(path)) }, Path)
end

function Path:kind()
  local stat = vim.uv.fs_stat(self._path)
  return stat and (stat.type == 'directory' and 'dir' or 'file')
end

function Path:parts()
  --- @type string[]
  local parts = {}
  local curr = self._path
  while #curr > 0 and curr ~= '.' and curr ~= '/' do
    table.insert(parts, 1, vim.fs.basename(curr))
    curr = vim.fs.dirname(curr)
  end
  return parts
end

function Path:parent()
  local path = vim.fs.dirname(self._path)
  if path == self._path then return end
  return Path.new(path)
end

--- @param to_path morph.examples.Path
function Path:steps_to(to_path)
  local rel_path = vim.fs.relpath(self._path, to_path._path)
  if not rel_path then return end

  --- @type string[]
  local rel_steps = {}
  local curr_rel = rel_path
  while curr_rel ~= vim.fs.dirname(curr_rel) do
    local part = vim.fs.basename(curr_rel)
    table.insert(rel_steps, part)
    curr_rel = vim.fs.dirname(curr_rel)
  end
  rel_steps = vim.iter(rel_steps):rev():totable()

  --- @type morph.examples.Path[]
  local steps = {}
  local curr = self._path
  for _, step in ipairs(rel_steps) do
    curr = vim.fs.joinpath(curr, step)
    table.insert(steps, Path.new(curr))
  end

  return steps
end

function Path:ls()
  if self:kind() == 'file' then return end
  --- @type morph.examples.Path[]
  local children = {}
  for nm, _ty in vim.fs.dir(self._path, { depth = 1 }) do
    table.insert(children, Path.new(vim.fs.joinpath(self._path, nm)))
  end
  table.sort(children, function(p1, p2)
    local p1kind, p2kind = p1:kind(), p2:kind()
    if p1kind ~= p2kind then return p1kind == 'dir' end
    return p1._path < p2._path
  end)
  return children
end

function Path:make_enclosing_dirs()
  local parent = self:parent()
  if parent == nil then return end
  vim.uv.fs_mkdir(parent._path, assert(tonumber('755', 8)))
end
-- }}}

-- morph.examples.Tree {{{
--------------------------------------------------------------------------------
-- morph.examples.Tree
-- A "tree" is the next layer of abstraction up from a "path". This is a
-- normalized structure (which makes live-updating easier/cleaner to handle).
-- Instead of storing structured/nested "nodes", the tree is stored flatly,
-- where attributes of nodes (like what their children are, or whether or not
-- they are expanded) is looked up external to the node. Nodes are addressed by
-- their path (i.e., their path is their unique ID in the tree structure).
--------------------------------------------------------------------------------

--- @class morph.examples.Tree
--- @field _root morph.examples.Path
--- @field _children table<string, morph.examples.Path[]>
--- @field _expanded table<string, boolean>
--- @field _render_lines table<string, integer>
--- @field _current_render_line integer
local Tree = {}
Tree.__index = Tree

--- @param root morph.examples.Path
function Tree.new(root)
  --- @type morph.examples.Tree
  local self = setmetatable({
    _root = root,
    _children = {},
    _expanded = {},
    _render_lines = {},
    _current_render_line = 1,
  }, Tree)
  self:set_expanded(root, true)
  return self
end

--- @param path morph.examples.Path
function Tree:children(path)
  self._children[path._path] = self._children[path._path] or path:ls()
  return self._children[path._path]
end

--- @param path morph.examples.Path
function Tree:is_expanded(path)
  local x = self._expanded[path._path]
  if x == nil then x = false end
  return x
end

--- @param path morph.examples.Path
--- @param expanded boolean
function Tree:set_expanded(path, expanded)
  self._expanded[path._path] = expanded
  if expanded then
    -- refresh the list:
    self._children[path._path] = path:ls()
  end
end

function Tree:refresh()
  -- clear _children cache:
  self._children = {}
end

--- @param path morph.examples.Path
--- @param child morph.examples.Path
function Tree:create(path, child)
  assert(path:kind() == 'dir', 'can only create files inside directories')

  child:make_enclosing_dirs()

  local f = assert(io.open(child._path, 'w+'))
  f:write ''
  f:close()

  self._children[path._path] = path:ls()
end

--- @param path morph.examples.Path
--- @param new_dir morph.examples.Path
function Tree:create_dir(path, new_dir)
  assert(path:kind() == 'dir', 'can only create directories inside directories')

  if new_dir:kind() ~= nil then
    -- already exists, bail
    return
  end

  new_dir:make_enclosing_dirs()

  vim.uv.fs_mkdir(new_dir._path, assert(tonumber('755', 8)))

  self._children[path._path] = path:ls()
  self._children[new_dir._path] = new_dir:ls()
end

--- @param path morph.examples.Path
--- @param new_base_name string
function Tree:rename(path, new_base_name)
  assert(path:kind() == 'file', 'can only rename files')

  local parent_dir = assert(path:parent(), 'unreachable')
  local new_path = vim.fs.joinpath(parent_dir._path, new_base_name)

  assert(vim.uv.fs_rename(path._path, new_path))

  self._children[parent_dir._path] = parent_dir:ls()
end
-- }}}

--- @param ctx morph.Ctx<{ path: morph.examples.Path, tree: morph.examples.Tree, level: integer, refresh: function }>
--- @return morph.Tree
local function FsNode(ctx)
  if ctx.phase == 'mount' then
    -- Initialize:
  end

  local tree = ctx.props.tree
  local path = ctx.props.path
  local kind = path:kind()
  local is_expanded = tree:is_expanded(path)

  local hl, icon
  if kind == 'dir' then
    hl = 'Directory'
    icon = is_expanded and '' or ''
  else
    hl = 'NonText'
    icon = 'f'
  end

  local children = {}
  if kind == 'dir' and is_expanded then
    for _, child in ipairs(tree:children(path)) do
      table.insert(children, '\n')
      table.insert(
        children,
        h(FsNode, {
          key = child._path,
          path = child,
          tree = ctx.props.tree,
          level = ctx.props.level + 1,
          refresh = ctx.props.refresh,
        })
      )
    end
  end

  return h('text', {
    nmap = {
      h = function(e)
        e.bubble_up = false

        --- @type morph.examples.Path | nil
        local to_focus

        if kind == 'dir' then
          if is_expanded then
            -- If the directory itself is expanded, then collapse it:
            tree:set_expanded(path, false)
            to_focus = path
          else
            -- If this directory is not expanded, then collapse our parent:
            to_focus = assert(path:parent())
            tree:set_expanded(to_focus, false)
          end
        else
          -- This entry is a file, collapse our parent (a directory):
          to_focus = assert(path:parent())
          tree:set_expanded(to_focus, false)
        end
        ctx.props.refresh(to_focus)
        return ''
      end,

      l = function(e)
        e.bubble_up = false
        local to_focus
        if kind == 'dir' then
          tree:set_expanded(path, true)
          to_focus = tree:children(path)[1]
        else
          -- Edit file:
          vim.notify((':edit %s'):format(vim.fs.basename(path._path)))
        end
        ctx.props.refresh(to_focus)
        return ''
      end,
    },
  }, {
    -- Indent this entry:
    ('  '):rep(ctx.props.level),

    h('text', { key = path, hl = hl }, { icon }),
    ' ',

    -- Show the entry name:
    h('text', {
      id = ('%s-label'):format(path._path),
      on_change = function(e)
        e.bubble_up = false
        -- Simple notification:
        vim.notify(('C %s => %s'):format(vim.fs.basename(path._path), e.text))
      end,
    }, { vim.fs.basename(path._path) }),

    is_expanded and children,
  })
end

--- @param ctx morph.Ctx<{ root?: string }, { focused?: morph.examples.Path, tree: morph.examples.Tree }>
--- @return morph.Tree
local function App(ctx)
  if ctx.phase == 'mount' then
    -- Initialize:
    local root_path = Path.new(ctx.props.root or assert(vim.uv.cwd()))
    local tree = Tree.new(root_path)
    ctx.state = { tree = tree, focused = root_path }
  end

  local state = assert(ctx.state)

  --- @param focused? morph.examples.Path
  local refresh = function(focused)
    if focused then state.focused = focused end
    ctx:update(state)
  end

  if ctx.phase ~= 'unmount' then
    if state.focused then
      local to_focus = state.focused._path
      -- Nil out the focused state, but don't re-render:
      state.focused = nil

      ctx:do_after_render(function()
        local doc = assert(ctx.document)
        local elem = doc:get_element_by_id(('%s-label'):format(to_focus))
        if elem then
          local pos = elem.extmark.start
          vim.api.nvim_win_set_cursor(0, { pos[1] + 1, pos[2] })
        end
      end)
    end
  end

  return h(FsNode, {
    path = state.tree._root,
    tree = state.tree,
    level = 0,
    refresh = refresh,
  })
end

local function show()
  vim.cmd.vnew()
  vim.bo.bufhidden = 'delete'
  vim.bo.buflisted = false
  vim.bo.buftype = 'nowrite'
  vim.wo[0][0].list = true
  vim.wo[0][0].listchars = 'leadmultispace:┆ '
  vim.wo[0][0].number = false
  vim.wo[0][0].relativenumber = false
  vim.bo[0].shiftwidth = 2
  vim.bo[0].tabstop = 2

  Morph.new():mount(h(App))
end

show()
