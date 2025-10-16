local Morph = require 'morph'
local h = Morph.h

--- @param ctx morph.Ctx<any, { text: string, hl?: string, on_click?: function }>
local function Button(ctx)
  return h('text', {
    hl = ctx.props.hl or 'DiffAdd',
    nmap = {
      ['<CR>'] = function()
        if ctx.props.on_click then ctx.props.on_click() end
        return ''
      end,
    },
  }, ctx.props.text)
end

--- @param ctx morph.Ctx<{ count: integer }>
local function Counter(ctx)
  if ctx.phase == 'mount' then ctx.state = { count = 1 } end
  local state = assert(ctx.state)

  return {
    'Value: ',
    h.Number({}, tostring(state.count)),
    ' ',
    h(Button, {
      text = ' - ',
      hl = 'DiffDelete',
      on_click = function() ctx:update { count = state.count - 1 } end,
    }),
    ' / ',
    h(Button, {
      text = ' + ',
      hl = 'DiffAdd',
      on_click = function() ctx:update { count = state.count + 1 } end,
    }),
  }
end

--- @param _ctx morph.Ctx
--- @return morph.Tree
local function App(_ctx)
  return {
    h['@markup.heading']({}, '# Counter Example'),

    '\n\n',
    'Each of the following counters are rendered by a Counter component, each with its own retained state:',

    '\n\n',
    { h['@markup.heading.2.markdown']({}, 'Counter 1:'), '\n' },
    h(Counter),

    '\n\n',
    h['@markup.heading.2.markdown']({}, 'Counter 2:'),
    '\n',
    h(Counter),

    '\n\n',
    'Press <CR> on each "button" above to increment/decrement the counter.',
  } --[[@as morph.Tree]]
end

-- Create an buffer for the UI
vim.cmd.vnew()
vim.bo.bufhidden = 'delete'
vim.bo.buflisted = false
vim.bo.buftype = 'nowrite'
Morph.new():mount(h(App, {}))
