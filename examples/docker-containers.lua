local Morph = require 'morph'
local h = Morph.h

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

--- @class morph.examples.DockerContainer
--- @field id string
--- @field name string
--- @field image string
--- @field status string
--- @field ports string
--- @field created string
--- @field raw unknown

--- @param cmd string
--- @param pos 'J' | 'L'
local function show_term(cmd, pos)
  vim.cmd '20new'
  vim.cmd.wincmd(pos)

  vim.bo.buflisted = false
  vim.wo[0][0].number = false
  vim.wo[0][0].relativenumber = false
  vim.cmd.terminal(cmd)
  vim.cmd.startinsert()
end

--- @param ctx morph.Ctx<{ cells: morph.Tree[][] }>
local function Table(ctx)
  local cells = ctx.props.cells
  local max_widths = {}

  -- Calculate max width for each column
  for col_idx = 1, #cells[1] do
    local max_width = 0
    for row_idx = 1, #cells do
      local cell = cells[row_idx][col_idx]
      local cell_text = Morph.markup_to_string { tree = cell }
      local width = #cell_text + 1
      if width > max_width then max_width = width end
    end
    max_widths[col_idx] = max_width
  end

  local result = {}

  for row_idx, row in ipairs(cells) do
    if row_idx > 1 then table.insert(result, '\n') end

    for col_idx, cell in ipairs(row) do
      table.insert(result, cell)

      if col_idx < #row then
        -- Calculate padding needed for this cell
        local cell_text = Morph.markup_to_string { tree = cell }
        local cell_width = #cell_text
        --- @type integer
        local needed_padding = max_widths[col_idx] - cell_width

        if needed_padding > 0 then table.insert(result, string.rep(' ', needed_padding)) end
      end
    end
  end

  return result
end

--  _   _      _
-- | | | | ___| |_ __
-- | |_| |/ _ \ | '_ \
-- |  _  |  __/ | |_) |
-- |_| |_|\___|_| .__/
--              |_|

--- @param ctx morph.Ctx<{ show_help: boolean }, any>
local function Help(ctx)
  if not ctx.props.show_help then return {} end

  local help_table = {}

  table.insert(help_table, {
    h.Constant({}, 'KEY'),
    h.Constant({}, 'DESCRIPTION'),
  })

  local keymaps = {
    { 'gi', 'Inspect container (JSON)' },
    { 'gl', 'View container logs' },
    { 'gx', 'Execute bash in container' },
    { 'gs', 'Start/stop container' },
    { 'gr', 'Restart container' },
    { '<Leader>r', 'Refresh containers' },
    { 'g?', 'Toggle this help' },
  }

  for _, keymap in ipairs(keymaps) do
    table.insert(help_table, {
      h.Title({}, keymap[1]),
      h.Normal({}, keymap[2]),
    })
  end

  return {
    h['@markup.heading']({}, '## Help'),
    '\n\n',
    h(Table, { cells = help_table }),
  }
end

--   ____            _        _
--  / ___|___  _ __ | |_ __ _(_)_ __   ___ _ __ ___
-- | |   / _ \| '_ \| __/ _` | | '_ \ / _ \ '__/ __|
-- | |__| (_) | | | | || (_| | | | | |  __/ |  \__ \
--  \____\___/|_| |_|\__\__,_|_|_| |_|\___|_|  |___/

--- @param ctx morph.Ctx<{ loading: boolean, containers: morph.examples.DockerContainer[] }, { filter: string }>
local function Containers(ctx)
  if ctx.phase == 'mount' then ctx.state = { filter = '' } end
  local state = assert(ctx.state)

  local containers_table = {}

  table.insert(containers_table, {
    h.Constant({}, 'NAME'),
    h.Constant({}, 'IMAGE'),
    h.Constant({}, 'ID'),
    h.Constant({}, 'STATUS'),
    h.Constant({}, 'PORTS'),
  })

  for _, container in ipairs(ctx.props.containers) do
    local passes_filter = state.filter == ''
      or container.name:find(state.filter, 1, true) ~= nil
      or container.image:find(state.filter, 1, true) ~= nil
      or container.id:find(state.filter, 1, true) ~= nil

    if passes_filter then
      table.insert(containers_table, {
        h.Constant({
          nmap = {
            ['gi'] = function()
              vim.schedule(
                function()
                  show_term('docker inspect ' .. container.id .. ' | yq -Po yaml ".[0]"', 'L')
                end
              )
              return ''
            end,
            ['gl'] = function()
              vim.schedule(function() show_term('docker logs -f ' .. container.id, 'J') end)
              return ''
            end,
            ['gx'] = function()
              vim.schedule(
                function() show_term('docker exec -it ' .. container.id .. ' bash', 'J') end
              )
              return ''
            end,
            ['gs'] = function()
              vim.schedule(function()
                if container.status:find 'Up' then
                  show_term('docker stop ' .. container.id, 'J')
                else
                  show_term('docker start ' .. container.id, 'J')
                end
                vim.defer_fn(function() vim.cmd 'normal! \\<Leader>r' end, 1000)
              end)
              return ''
            end,
            ['gr'] = function()
              vim.schedule(function()
                show_term('docker restart ' .. container.id, 'J')
                vim.defer_fn(function() vim.cmd 'normal! \\<Leader>r' end, 1000)
              end)
              return ''
            end,
          },
        }, container.name),
        h.String({}, container.image),
        h.Normal({}, container.id),
        h[container.status:find 'Up' and 'DiagnosticOk' or 'DiagnosticError']({}, container.status),
        h.Comment({}, container.ports),
      })
    end
  end

  return {
    h['@markup.heading'](
      {},
      ('## Containers%s%s'):format(
        #state.filter > 0 and ' (filter: ' .. state.filter .. ')' or '',
        ctx.props.loading and '...' or ''
      )
    ),

    '\n\n',

    'Filter: [',
    h.String({
      on_change = function(e)
        state.filter = e.text
        ctx:update(state)
      end,
    }, state.filter),
    ']',

    ctx.props.containers and '\n\n' or '',

    h(Table, { cells = containers_table }),
  }
end

--     _
--    / \   _ __  _ __
--   / _ \ | '_ \| '_ \
--  / ___ \| |_) | |_) |
-- /_/   \_\ .__/| .__/
--         |_|   |_|

--- @param ctx morph.Ctx<any, { loading: boolean, containers: morph.examples.DockerContainer[], show_help: boolean }>
local function App(ctx)
  --
  -- Helper: refresh_containers:
  local refresh_containers = vim.schedule_wrap(function()
    local state = assert(ctx.state)
    state.loading = true
    ctx:update(state)

    local cmd = { 'docker', 'ps', '--format', 'json', '--all' }

    vim.system(cmd, { text = true }, function(out)
      ---@type morph.examples.DockerContainer[]
      local containers = {}

      local lines = vim
        .iter(vim.split(out.stdout or '', '\n'))
        :filter(function(l) return l ~= '' end)
        :totable()
      for _, line in ipairs(lines) do
        local raw_container = vim.json.decode(line)

        ---@type morph.examples.DockerContainer
        local container = {
          id = raw_container.ID or '',
          name = raw_container.Names or '',
          image = raw_container.Image or '',
          status = raw_container.Status or '',
          ports = raw_container.Ports or '',
          created = raw_container.CreatedAt or '',
          raw = raw_container,
        }
        table.insert(containers, container)
      end

      table.sort(containers, function(a, b) return a.name < b.name end)

      state.loading = false
      state.containers = containers
      ctx:update(state)
    end)
  end)

  if ctx.phase == 'mount' then
    -- Initialize state:
    ctx.state = {
      loading = false,
      containers = {},
      show_help = false,
    }
    refresh_containers()
  end
  local state = assert(ctx.state)

  return h('text', {
    -- Global maps:
    nmap = {
      ['<Leader>r'] = function()
        refresh_containers()
        return ''
      end,
      ['g?'] = function()
        state.show_help = not state.show_help
        ctx:update(state)
        return ''
      end,
    },
  }, {
    h['@markup.heading']({}, '# Docker'),
    '\n\n',

    --
    -- Help (if enabled)
    --
    state.show_help
      and {
        h(Help, {
          show_help = state.show_help,
        }),
        '\n\n',
      },

    --
    -- List of containers
    --
    {
      h(Containers, {
        loading = state.loading,
        containers = state.containers,
      }),
    },
  })
end

--------------------------------------------------------------------------------
-- Buffer/Render
--------------------------------------------------------------------------------

vim.cmd.tabnew()
vim.bo.buftype = 'nofile'
vim.bo.bufhidden = 'wipe'
vim.bo.buflisted = false
Morph.new():mount(h(App))
