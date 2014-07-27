###
context_fns: context functions collected from all modules. unbound
imported_context_fns: context_fns + the fns from all modules listed in imports
fns: imported_context_fns, bound to the scope_context
###

_ = require 'underscore'
printStackTrace = require 'stacktrace-js'
Bacon = require 'bacon.model'
React = require './react_abuse'

# CAREFUL ABOUT PUTTING MORE IMPORTS HERE! OTHER MODULES DEPEND ON THE COMPONENTS BELOW

contexts_by_root_node_id = {}

find_ancestor_contexts = (component_instance) ->
  result = []
  _.each React.__internals.InstanceHandles.traverseAncestors component_instance._rootNodeID, (id) ->
    context = contexts_by_root_node_id[id]
    if context
      result.unshift context
  result

ContextRegisteringMixin =
  componentWillMount: ->
    contexts_by_root_node_id[@_rootNodeID] = @props.ctx
  componentWillUnmount: ->
    delete contexts_by_root_node_id[@_rootNodeID]

ContextAwareMixin =
  contextTypes: ctx: React.PropTypes.object
  getInitialState: ->
    ctx: find_ancestor_contexts(@)[0]

ComponentContextComponent = React.createIdentityClass
  displayName: 'ComponentContextComponent'
  mixins: [ContextRegisteringMixin]
  render: -> React.DOM.div null, @props.children

_.extend exports, {
  ComponentContextComponent,
  ContextAwareMixin
}

Builtins = require './builtins'
Modules = require './modules'

ignore = new Object

running_context_binding = null

# statement result handlers. return truthy if handled.
ignored = (ctx, object) -> object == ignore

handle_cmd = (ctx, object) ->
  if (op = object?._lead_context_fn)?
    if op.cmd_fn?
      op.cmd_fn.call null, ctx
      true
    else
      add_component ctx, React.DOM.div null,
        "Did you forget to call a function? \"#{object._lead_context_name}\" must be called with arguments."
        Builtins.help_component object
      true

handle_module = (ctx, object) ->
  if object?._lead_context_name
    add_component ctx, React.DOM.div null,
      "#{object._lead_context_name} is a module."
      Builtins.help_component object
    true

handle_using_extension = (ctx, object) ->
  handlers = collect_extension_points ctx, 'context_result_handler'
  _.find handlers, (handler) -> handler ctx, object

handle_any_object = (ctx, object) ->
  add_component ctx, Builtins.context_fns.object.fn.raw_fn ctx, object
  true

# TODO make this configurable
result_handlers =[
  ignored
  handle_cmd
  handle_module
  handle_using_extension
  handle_any_object
]

display_object = (ctx, object) ->
  for handler in result_handlers
    return if handler ctx, object

collect_extension_points = (context, extension_point) ->
  Modules.collect_extension_points context.modules, extension_point

collect_context_vars = (context) ->
  module_vars = (module, name) ->
    vars = module.context_vars
    if _.isFunction vars
      vars = vars.call context
    [name, vars]

  _.object _.filter _.map(context.modules, module_vars), ([n, f]) -> f

collect_context_fns = (context) ->
  _.object _.filter _.map(context.modules, (module, name) -> [name, module.context_fns]), ([n, f]) -> f

is_run_context = (o) ->
  o?.component_list?

bind_fn_to_current_context = (scope_context, fn) ->
  (args...) ->
    args.unshift scope_context.current_context
    fn.apply scope_context.current_context, args

bind_context_fns = (scope_context, fns, name_prefix='') ->
  result = {}
  for k, o of fns
    do (k, o) ->
      if _.isFunction o.fn
        name = "#{name_prefix}#{k}"
        wrapped_fn = ->
          o.fn.apply(null, arguments)?._lead_context_fn_value ? ignore
        bound = bind_fn_to_current_context scope_context, wrapped_fn
        bound._lead_context_fn = o
        bound._lead_context_name = name
        result[k] = bound
      else
        result[k] = _.extend {_lead_context_name: k}, bind_context_fns scope_context, o, k + '.'

  result

AsyncComponent = React.createIdentityClass
  displayName: 'AsyncComponent'
  mixins: [ContextAwareMixin]
  componentWillMount: ->
    register_promise @state.ctx, @props.promise
  componentWillUnmount: ->
    # FIXME should unregister
  render: ->
    React.DOM.div null, @props.children

ContextComponent = React.createIdentityClass
  displayName: 'ContextComponent'
  mixins: [ContextRegisteringMixin, React.ObservableMixin]
  get_observable: -> @props.model
  propTypes:
    ctx: (c) -> throw new Error("context required") unless is_run_context c['ctx']
    # TODO type
    model: React.PropTypes.object.isRequired
    layout: React.PropTypes.func.isRequired
    layout_props: React.PropTypes.object
  render: ->
    @props.layout _.extend {children: @state.value}, @props.layout_props

# the base context contains the loaded modules, and the list of modules to import into every context
create_base_context = ({module_names, imports}) ->
  modules = Modules.get_modules(_.union imports or [], module_names or [])
  {modules, imports}

# the XXX context contains all the context functions and vars. basically, everything needed to support
# an editor
create_context = (base) ->
  context_fns = collect_context_fns base
  imported_context_fns = _.clone context_fns
  _.extend imported_context_fns, _.map(base.imports, (i) -> context_fns[i])...

  vars = collect_context_vars base
  imported_vars = _.extend {}, _.map(base.imports, (i) -> vars[i])...

  context = _.extend {}, base,
    context_fns: context_fns
    imported_context_fns: imported_context_fns
    vars: vars
    imported_vars: imported_vars

# FIXME figure out a real check for a react component
is_component = (o) -> o?.__realComponentInstance?

component_for_renderable = (renderable) ->
  if is_component renderable
    renderable
  # TODO remove context special case
  else if is_run_context renderable
    renderable.component

component_list = ->
  components = []
  model = new Bacon.Model []

  model: model
  add_component: (c) ->
    unless c.props.key?
      c = React.addons.cloneWithProps c, key: "#{c.constructor.displayName ? 'component'}_#{React.generate_component_id()}"
    components.push c
    model.set components.slice()
  empty: ->
    components = []
    model.set []

add_component = (ctx, component) ->
  ctx.component_list.add_component component

remove_all_components = (ctx) ->
  ctx.component_list.empty()

# creates a nested context, adds it to the component list, and applies the function to it
nested_item = (ctx, fn, args...) ->
  nested_context = create_nested_context ctx
  add_component ctx, nested_context.component
  apply_to nested_context, fn, args

apply_to = (ctx, fn, args) ->
  previous_context = ctx.scope_context.current_context
  ctx.scope_context.current_context = ctx
  try
    fn.apply ctx, args
  finally
    ctx.scope_context.current_context = previous_context

value = (value) -> _lead_context_fn_value: value

# TODO this is an awful name
context_run_context_prototype =
  options: -> @current_options

  in_running_context: (fn, args) ->
    throw new Error 'no active running context. did you call an async function without keeping the context?' unless running_context_binding?
    apply_to running_context_binding, fn, args

  # returns a function that calls its argument in the current context
  capture_context: ->
    context = @
    running_context = running_context_binding
    (fn, args) ->
      previous_running_context_binding = running_context_binding
      running_context_binding = running_context
      try
        apply_to context, fn, args
      finally
        running_context_binding = previous_running_context_binding

  # wraps a function so that it is called in the current context
  keeping_context: (fn) ->
    restoring_context = @capture_context()
    ->
      restoring_context fn, arguments

register_promise = (ctx, promise) ->
  ctx.asyncs.push 1
  promise.finally =>
    ctx.asyncs.push -1
    ctx.changes.push true

create_run_context = (extra_contexts) ->
  run_context_prototype = _.extend {}, extra_contexts..., context_run_context_prototype
  run_context_prototype.run_context_prototype = run_context_prototype
  scope_context = {}
  run_context_prototype.scoped_fns = bind_context_fns scope_context, run_context_prototype.imported_context_fns
  run_context_prototype.scope_context = scope_context

  result = create_nested_context run_context_prototype

  asyncs = new Bacon.Bus
  changes = new Bacon.Bus
  changes.plug result.component_list.model

  _.extend result,
    current_options: {}
    changes: changes
    asyncs: asyncs
    pending: asyncs.scan 0, (a, b) -> a + b

  scope_context.current_context = result

create_nested_context = (parent, overrides) ->
  new_context = _.extend Object.create(parent), {layout: React.SimpleLayoutComponent}, overrides
  new_context.component_list = component_list()
  new_context.component = ContextComponent
    ctx: new_context
    model: new_context.component_list.model
    layout: new_context.layout
    layout_props: new_context.layout_props

  new_context.current_context = new_context
  new_context

scope = (run_context) ->
  _.extend {}, run_context.scoped_fns, run_context.imported_vars

create_standalone_context = ({imports, module_names}={}) ->
  base_context = create_base_context({imports: ['builtins'].concat(imports or []), module_names})
  create_run_context [create_context base_context]

scoped_eval = (ctx, string) ->
  if _.isFunction string
    string = "(#{string}).apply(this);"
  context_scope = scope ctx
  `with (context_scope) {`
  result = (-> eval string).call ctx
  `}`
  result

eval_in_context = (run_context, string) ->
  run_in_context run_context, (ctx) -> scoped_eval ctx, string

run_in_context = (run_context, fn) ->
  try
    previous_running_context_binding = running_context_binding
    running_context_binding = run_context
    result = fn run_context
    display_object run_context, result
  finally
    running_context_binding = previous_running_context_binding

_.extend exports, {
  create_base_context,
  create_context,
  create_run_context,
  create_standalone_context,
  create_nested_context,
  run_in_context,
  eval_in_context,
  scope,
  collect_extension_points,
  is_run_context,
  register_promise,
  apply_to,
  value,
  scoped_eval,
  add_component,
  remove_all_components,
  nested_item,
  AsyncComponent,
  IGNORE: ignore
}
