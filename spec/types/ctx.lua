-- morph.Ctx must substitute both of its type parameters into a component's
-- ctx. `state` stays optional, because it is nil until the mount phase sets
-- it, so a component must narrow it before reading a field.

--- @class types.CtxProps
--- @field label string

--- @class types.CtxState
--- @field count integer

--- @param ctx morph.Ctx<types.CtxProps, types.CtxState>
return function(ctx)
  --- @type string
  local _label = ctx.props.label
  --- @type boolean
  local _wrong_prop = ctx.props.label -- expect: assign-type-mismatch

  local _unnarrowed = ctx.state.count -- expect: need-check-nil

  local state = assert(ctx.state)
  --- @type integer
  local _count = state.count
  --- @type boolean
  local _wrong_state = state.count -- expect: assign-type-mismatch

  return {}
end
