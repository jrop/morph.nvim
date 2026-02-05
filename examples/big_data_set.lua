local Morph = require 'morph'
local h = Morph.h

local H = {}

---
--- This is the part that gets really expensive, and why this is a somewhat
--- useful test. This `Table` component (inefficiently implemented) makes the
--- UI stutter.
---
--- @param ctx morph.Ctx<{ cells: morph.Tree[][] }>
local function Table(ctx)
  local cells = ctx.props.cells
  local max_widths = {}

  -- Cache for cell text to avoid calling markup_to_string twice per cell
  local cell_text_cache = {}

  -- Calculate max width for each column
  for col_idx = 1, #cells[1] do
    local max_width = 0
    for row_idx = 1, #cells do
      local cell = cells[row_idx][col_idx]
      -- Cache the result of markup_to_string
      if not cell_text_cache[row_idx] then cell_text_cache[row_idx] = {} end
      local cell_text = Morph.markup_to_string { tree = cell }
      cell_text_cache[row_idx][col_idx] = cell_text
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
        -- Use cached cell text instead of recalculating
        local cell_text = cell_text_cache[row_idx][col_idx]
        local cell_width = #cell_text
        --- @type integer
        local needed_padding = max_widths[col_idx] - cell_width

        if needed_padding > 0 then table.insert(result, string.rep(' ', needed_padding)) end
      end
    end
  end

  return result
end

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

--- @param ctx morph.Ctx<{ users: { first_name: string, last_name: string, email: string, username: string }[] }, { filter: string }>
local function Users(ctx)
  if ctx.phase == 'mount' then ctx.state = { filter = '' } end
  local state = assert(ctx.state)

  local table_cells = {}

  -- Header row
  table.insert(table_cells, {
    h.Constant({}, 'FIRST NAME'),
    h.Constant({}, 'LAST NAME'),
    h.Constant({}, 'EMAIL'),
    h.Constant({}, 'USERNAME'),
  })

  -- Data rows
  for _, item in ipairs(ctx.props.users) do
    local passes_filter = state.filter == ''
      or item.first_name:find(state.filter, 1, true) ~= nil
      or item.last_name:find(state.filter, 1, true) ~= nil
      or item.email:find(state.filter, 1, true) ~= nil
      or item.username:find(state.filter, 1, true) ~= nil
    if passes_filter then
      local props = {
        nmap = {
          ['<Leader>x'] = function()
            state.filter = 'william'
            ctx:update(state)
            return ''
          end,
        },
      }
      table.insert(table_cells, {
        h.Text(props, item.first_name),
        h.Text(props, item.last_name),
        h.String(props, item.email),
        h.String(props, item.username),
      })
    end
  end

  return {
    'Filter: [',
    h.String({
      on_change = function(e)
        state.filter = e.text
        ctx:update(state)
      end,
    }, state.filter),
    ']',
    '\n\n',

    h(Table, { cells = table_cells }),
  }
end

--     _
--    / \   _ __  _ __
--   / _ \ | '_ \| '_ \
--  / ___ \| |_) | |_) |
-- /_/   \_\ .__/| .__/
--         |_|   |_|

--- @param _ctx morph.Ctx
local function App(_ctx)
  return h('text', {}, {
    --
    -- List of items
    --
    h(Users, { users = H.USERS }),
  })
end

-- Data set {{{
local function generate_users(n)
  if type(n) ~= 'number' or n < 1 or n ~= math.floor(n) then
    error 'Parameter must be a positive integer'
  end

  -- Initialize random seed (do this once in your application)
  -- math.randomseed(os.time())

  --- @type string[]
  local first_names = {
    'James',
    'Mary',
    'John',
    'Patricia',
    'Robert',
    'Jennifer',
    'Michael',
    'Linda',
    'William',
    'Elizabeth',
    'David',
    'Barbara',
    'Richard',
    'Susan',
    'Joseph',
    'Jessica',
    'Thomas',
    'Sarah',
    'Charles',
    'Karen',
    'Christopher',
    'Nancy',
    'Daniel',
    'Lisa',
    'Matthew',
    'Betty',
    'Anthony',
    'Margaret',
    'Mark',
    'Sandra',
    'Donald',
    'Ashley',
    'Steven',
    'Kimberly',
    'Paul',
    'Emily',
    'Andrew',
    'Donna',
    'Joshua',
    'Michelle',
  }

  --- @type string[]
  local last_names = {
    'Smith',
    'Johnson',
    'Williams',
    'Brown',
    'Jones',
    'Garcia',
    'Miller',
    'Davis',
    'Rodriguez',
    'Martinez',
    'Hernandez',
    'Lopez',
    'Gonzalez',
    'Wilson',
    'Anderson',
    'Thomas',
    'Taylor',
    'Moore',
    'Jackson',
    'Martin',
    'Lee',
    'Perez',
    'Thompson',
    'White',
    'Harris',
    'Sanchez',
    'Clark',
    'Ramirez',
    'Lewis',
    'Robinson',
    'Walker',
  }

  --- @type string[]
  local domains = {
    'gmail.com',
    'yahoo.com',
    'outlook.com',
    'hotmail.com',
    'icloud.com',
    'protonmail.com',
    'example.com',
    'mail.com',
    'company.net',
    'email.org',
  }

  local users = {}

  for _i = 1, n do
    local first = first_names[math.random(#first_names)] --[[@as string]]
    local last = last_names[math.random(#last_names)] --[[@as string]]
    local domain = domains[math.random(#domains)] --[[@as string]]

    -- Generate varied username patterns
    local username
    local pattern = math.random(6)

    if pattern == 1 then
      username = first:lower() .. '_' .. last:lower()
    elseif pattern == 2 then
      username = first:lower() .. '.' .. last:lower()
    elseif pattern == 3 then
      username = first:lower():sub(1, 1) .. last:lower()
    elseif pattern == 4 then
      username = first:lower() .. last:lower():sub(1, 3)
    elseif pattern == 5 then
      username = last:lower() .. '.' .. first:lower()
    else
      username = first:lower() .. last:lower()
    end

    -- 40% chance to append random number for realism
    if math.random() <= 0.4 then username = username .. tostring(math.random(1, 999)) end

    table.insert(users, {
      first_name = first,
      last_name = last,
      username = username,
      email = username .. '@' .. domain,
    })
  end

  return users
end
H.USERS = generate_users(10000)
-- }}}

--------------------------------------------------------------------------------
-- Buffer/Render
--------------------------------------------------------------------------------

vim.cmd.vnew()
vim.bo.buftype = 'nofile'
vim.bo.bufhidden = 'wipe'
vim.bo.buflisted = false
vim.b.completion = false

require('jit.p').start('vfl', '/tmp/profile')

vim.keymap.set('n', '<Leader>S', function()
  require('jit.p').stop()
  vim.cmd.tabnew '/tmp/profile'
end, { buffer = true })

Morph.new():mount(h(App))
