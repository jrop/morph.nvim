-- morph.TagAttributes must declare `id`, because Morph:get_element_by_id looks
-- tags up by it, so a caller reads it back as a string rather than unknown.

local h = require('morph').h

local _tag = h('text', { id = 'query' }, 'x')

--- @type morph.TagAttributes
local attrs = { id = 'query' }
--- @type string?
local _id = attrs.id

--- @type morph.TagAttributes
local _bad = { id = 1 } -- expect: assign-type-mismatch, assign-type-mismatch
