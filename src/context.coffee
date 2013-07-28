define (require) ->
  $ = require 'jquery'
  _ = require 'underscore'
  CoffeeScript = require 'lib/coffee-script'
  printStackTrace = require 'stacktrace-js'
  modules = require 'modules'
  dsl = require 'dsl'

  ignore = new Object

  # statement result handlers. return truthy if handled.
  ignored = (object) -> object == ignore

  handle_cmd = (object) ->
    if object?._lead_context_fn?
      object._lead_context_fn.cmd_fn.apply @
      true

  handle_renderable = (object) ->
    if fn = object?._lead_render
      fn.apply @

  handle_using_extension = (object) ->
    handlers = modules.collect_extension_points @notebook.modules, 'context_result_handler'
    context = @
    _.find handlers, (handler) -> handler.call context, object

  handle_any_object = (object) ->
    @fns.object object
    true


  bind_context_fns = (run_context, fns) ->
    bind_fn = (op) ->
      bound = (args...) ->
        # if the function returned a value, unwrap it. otherwise, ignore it
        op.fn.apply(run_context.root_context.current_context, args)?._lead_context_fn_value ? ignore
      bound._lead_context_fn = op
      bound

    bound_fns = {}
    for k, o of fns
      if _.isFunction o.fn
        bound_fns[k] = bind_fn o
      else
        bound_fns[k] = bind_context_fns run_context, o

    bound_fns

  create_run_context = ($el, opts={}) ->
    {extra_contexts, context_fns, function_names} = _.defaults {}, opts,
      extra_contexts: []
      context_fns: {}
      function_names: []

    scroll_to_top = ->
      setTimeout ->
        $('html, body').scrollTop $el.offset().top
      , 10

    result_handlers =[
      ignored,
      handle_cmd,
      handle_renderable,
      handle_using_extension
      handle_any_object
    ]

    output = ($target) ->
      (output) ->
        $target.removeClass 'clean'
        $item = $ '<div class="item"/>'
        if output?
          $item.append output
        $target.append $item
        $item

    run_context =
      context_fns: context_fns
      current_options: {}
      output: output $el
      scroll_to_top: scroll_to_top
      functions: dsl.define_functions {}, function_names

      in_context: (context, fn) ->
        previous_context = @root_context.current_context
        @root_context.current_context = context
        context_overridden = @root_context.context_overridden
        @root_context.context_overridden = true
        try
          fn()
        finally
          @root_context.current_context = previous_context
          @root_context.context_overridden = context_overridden

      render: (o) ->
        @nested 'renderable', handle_renderable, o
        # TODO warn if not renderable

      nested: (className, fn, args...) ->
        $item = $ "<div class='#{className}'/>"
        @nested_item $item, fn, args...

      nested_item: ($item, fn, args...) ->
        @output $item

        nested_context = _.extend {}, run_context,
          output: output $item
        nested_context.current_context = nested_context
        nested_context.fns = bind_context_fns nested_context, context_fns
        fn.apply nested_context, args

      handle_exception: (e, compiled) ->
        console.error e.stack
        @fns.error printStackTrace({e}).join('\n')
        @fns.text 'Compiled JavaScript:'
        @fns.source 'javascript', compiled

      error: (message) ->
        $pre = $ '<pre class="error"/>'
        $pre.text message
        run_context.output $pre

      display_object: (object) ->
        for handler in result_handlers
          return if handler.call run_context, object

      value: (value) -> _lead_context_fn_value: value

      async: (fn) ->
        $item = $ '<div class="async"/>'
        $item.attr 'data-async-status', 'loading'

        start_time = new Date

        duration = ->
          ms = new Date - start_time
          if ms >= 1000
            s = (ms / 1000).toFixed 1
            "#{s} s"
          else
            "#{ms} ms"

        promise = @nested_item $item, fn
        promise.done ->
          $item.attr 'data-async-status', "loaded in #{duration()}"
          scroll_to_top()
        promise.fail ->
          $item.attr 'data-async-status', "failed in #{duration()}"
          scroll_to_top()

    run_context.fns = fns = bind_context_fns run_context, context_fns
    run_context.current_context = run_context
    run_context.root_context = run_context
    _.defaults run_context, extra_contexts...

    run_context

  run_in_context = (run_context, string) ->
    try
      compiled = CoffeeScript.compile(string, bare: true) + "\n//@ sourceURL=console-coffeescript.js"
    catch e
      if e instanceof SyntaxError
        run_context.error "Syntax Error: #{e.message} at #{e.location.first_line + 1}:#{e.location.first_column + 1}"
      else
        run_context.handle_exception e, compiled

    if compiled?
      try
        `with (run_context.fns) { with (run_context.functions) {`
        result = eval compiled
        `}}`
        run_context.display_object result
      catch e
        run_context.handle_exception e, compiled


  {create_run_context, run_in_context}
