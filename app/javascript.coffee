acorn = require 'acorn'
walk = require 'acorn/util/walk'
_ = require 'underscore'

exports.mangle = (src) ->
  ast = acorn.parse src, ranges: true, locations: true
  chunks = src.split ''

  source = (node) ->
    chunks.slice(node.range[0], node.range[1]).join ''

  update = (node, s) ->
    chunks[node.range[0]] = s
    for i in [(node.range[0] + 1)...node.range[1]]
      chunks[i] = ''

  global_scope = vars: Object.create(null)
  functions = []

  walk.simple ast,
    ScopeBody: (node, scope) ->
      node.scope = scope
    Function: (node, scope, c) ->
      functions.push node
  , walk.scopeVisitor, global_scope

  _.each functions, (f) ->
    # TODO handle function definitions
    if f.type == 'FunctionExpression'
      paramNames = _.pluck(f.params, 'name')
      generatedFunctionName = '_f'
      i = 1
      while _.contains(paramNames, generatedFunctionName)
        generatedFunctionName = "_f#{i++}"
      update(f, "(function(unbound) {var #{generatedFunctionName} = _capture_context(unbound);var bound = function(#{paramNames.join(', ')}) {return #{generatedFunctionName}.apply(this, arguments);};bound._lead_unbound_fn = unbound;return bound;})(#{source(f)})")

  global_vars: Object.keys global_scope.vars
  source: chunks.join ''

