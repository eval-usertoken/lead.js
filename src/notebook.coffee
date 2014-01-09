define (require) ->
  $ = require 'jquery'
  _ = require 'underscore'
  CoffeeScript = require 'coffee-script'
  CodeMirror = require 'cm/codemirror'
  URI = require 'URIjs'
  Bacon = require 'baconjs'
  ed = require 'editor'
  http = require 'http'
  graphite = require 'graphite'
  context = require 'context'
  modules = require 'modules'
  React = require 'react_abuse'

  modules.create 'notebook', ({cmd}) ->
    cmd 'save', 'Saves the current notebook to a file', ->
      @div save @input_cell

    cmd 'load', 'Loads a script from a URL', (url, options={}) ->
      if arguments.length is 0
        open_file_picker @
      else
        @async ->
          promise = http.execute_xhr url, dataType: 'text', type: 'get'
          promise.then (xhr) =>
            handle_file @,
              filename: URI(url).filename()
              type: xhr.getResponseHeader 'content-type'
              content: xhr.responseText
            , options
          promise.fail (response) =>
            @error response.statusText
          promise

    cmd 'quiet', 'Hides the input cell', ->
      hide_cell @input_cell

    cmd 'clear', 'Clears the notebook', ->
      clear_notebook @notebook


    notebook_content_type = 'application/x-lead-notebook'

    forwards = +1
    backwards = -1

    # predicates for cells
    is_input = (cell) -> cell.type is 'input'
    is_output = (cell) -> cell.type is 'output'
    is_clean = (cell) -> cell.is_clean()
    visible = (cell) -> cell.visible
    identity = (cell) -> true


    init_codemirror = ->
      CodeMirror.keyMap.lead = ed.key_map
      _.extend CodeMirror.commands, ed.commands


    DocumentComponent = React.createClass
      mixins: [React.ComponentListMixin]
      render: ->
        React.DOM.div {className: 'document'}, @state.components
      set_cells: (cells) ->
        @set_components _.pluck cells, 'component'

    create_notebook = (opts) ->
      $file_picker = $ '<input type="file" id="file" class="file_picker"/>'
      $file_picker.on 'change', (e) ->
        for file in e.target.files
          load_file notebook.opening_run_context, file

        notebook.opening_run_context = null
        # reset the file picker so change is triggered again
        $file_picker.val ''

      document = DocumentComponent()
      # FIXME add file picker
      notebook =
        cells: []
        input_number: 1
        output_number: 1
        component: document
        $file_picker: $file_picker
        cell_run: new Bacon.Bus
        cell_focused: new Bacon.Bus

      unless is_nodejs?
        scrolls = $(window).asEventStream 'scroll'
        scroll_to = notebook.cell_run.flatMapLatest (input_cell) -> input_cell.output_cell.done.delay(0).takeUntil scrolls
        scroll_to.onValue (output_cell) ->
          # FIXME
          $('html, body').scrollTop $(output_cell.component.getDOMNode()).offset().top

      context.create_base_context(opts).then (base_context) ->
        notebook.base_context = base_context
        notebook

    export_notebook = (current_cell) ->
      lead_js_version: 0
      cells: current_cell.notebook.cells.filter((cell) -> cell != current_cell and is_input cell).map (cell) ->
        type: 'input'
        value: cell.editor.getValue()

    import_notebook = (notebook, cell, imported, options) ->
      for imported_cell in imported.cells
        if imported_cell.type is 'input'
          cell = add_input_cell notebook, after: cell
          set_cell_value cell, imported_cell.value
          if options.run
            run cell
      notebook

    update_view = (notebook) ->
      notebook.component.set_cells notebook.cells

    clear_notebook = (notebook) ->
      for cell in notebook.cells
        cell.active = false
      notebook.cells.length = 0
      update_view notebook


    cell_index = (cell) ->
      cell.notebook.cells.indexOf cell

    seek = (start_cell, direction, predicate=identity) ->
      notebook = start_cell.notebook
      index = cell_index(start_cell) + direction
      loop
        cell = notebook.cells[index]
        return unless cell?
        return cell if predicate cell
        index += direction

    input_cell_at_offset = (cell, offset) ->
      seek cell, offset, is_input

    get_input_cell_by_number = (notebook, number) ->
      for cell in notebook
        return cell if cell.number == number and is_input cell

    remove_cell = (cell) ->
      index = cell_index cell
      cell.notebook.cells.splice index, 1
      cell.active = false
      update_view cell.notebook

    hide_cell = (cell) ->
      cell.visible = false
      update_view cell.notebook

    insert_cell = (cell, position={}) ->
      if position.before?.active
        offset = 0
        current_cell = position.before
      else if position.after?.active
        offset = 1
        current_cell = position.after
      else
        cell.notebook.cells.push cell
        update_view cell.notebook
        return

      index = cell_index current_cell
      current_cell.notebook.cells.splice index + offset, 0, cell
      update_view cell.notebook

    # TODO cell type
    add_input_cell = (notebook, opts={}) ->
      if opts.reuse
        if opts.after?
          cell = seek opts.after, forwards, (cell) -> is_input(cell) and visible(cell)
        else if opts.before?
          cell = seek opts.before, backwards, (cell) -> is_input(cell) and visible(cell)
      unless cell? and is_clean cell
        cell = create_input_cell notebook
        insert_cell cell, opts
      cell

    # run an input cell above the current cell
    eval_coffeescript_before = (current_cell, code) ->
      cell = add_input_cell current_cell.notebook, before: current_cell
      set_cell_value cell, code
      run cell

    eval_coffeescript_after = (current_cell, code) ->
      cell = add_input_cell current_cell.notebook, after: current_cell
      set_cell_value cell, code
      run cell

    recompile = (error_marks, editor) ->
      m.clear() for m in error_marks
      editor.clearGutter 'error'
      try
        CoffeeScript.compile editor.getValue()
        []
      catch e
        [ed.add_error_mark editor, e]

    InputCellComponent = React.createClass
      render: ->
        # TODO handle hiding
        React.DOM.div {className: 'cell input', 'data-cell-number': @props.cell.number}, [
          React.DOM.span {className: 'permalink', onClick: @permalink_link_clicked}, 'link'
          React.DOM.div {className: 'code', ref: 'code'}
        ]
      componentDidMount: ->
        editor = @props.cell.editor
        @refs.code.getDOMNode().appendChild editor.display.wrapper
        editor.refresh()

      permalink_link_clicked: -> generate_permalink @props.cell

    generate_permalink = (cell) ->
      eval_coffeescript_after cell.output_cell ? cell, 'permalink'

    create_input_cell = (notebook) ->
      editor = ed.create_editor ->
      cell =
        type: 'input'
        visible: true
        active: true
        notebook: notebook
        context: create_input_context notebook
        used: false
        editor: editor
        is_clean: -> editor.getValue() is '' and not @.used

      editor.lead_cell = cell
      component = InputCellComponent {cell}
      cell.component = component

      changes = ed.as_event_stream editor, 'change'
      # scan changes for the side effect in in recompile
      # we have to subscribe so that the events are sent
      changes.debounce(200).scan([], recompile).onValue ->

      cell

    set_cell_value = (cell, value) ->
      cell.editor.setValue value
      cell.editor.setCursor(line: cell.editor.lineCount() - 1)

    focus_cell = (cell) ->
      cell.editor.focus()
      cell.notebook.cell_focused.push cell

    OutputCellComponent = React.createClass
      set_component: (@component) ->
        @setState component: @component if @state
      getInitialState: -> component_list: @component_list
      render: -> React.DOM.div {className: 'cell output clean', 'data-cell-number': @props.cell.number}, @state.component

    create_output_cell = (notebook) ->
      number = notebook.output_number++

      cell =
        type: 'output'
        visible: true
        active: true
        notebook: notebook
        number: number

      cell.component = OutputCellComponent {cell}
      cell

    run = (input_cell) ->
      string = input_cell.editor.getValue()
      output_cell = create_output_cell input_cell.notebook
      input_cell.used = true
      remove_cell input_cell.output_cell if input_cell.output_cell?
      insert_cell output_cell, after: input_cell
      input_cell.number = input_cell.notebook.input_number++
      input_cell.output_cell = output_cell

      # TODO cell type
      run_context = context.create_run_context [input_cell.context, {input_cell, output_cell}, create_notebook_run_context input_cell]
      eval_coffeescript_into_output_cell run_context, string
      input_cell.notebook.cell_run.push input_cell
      output_cell

    eval_coffeescript_into_output_cell = (run_context, string) ->
      run_with_context run_context, ->
        context.eval_coffeescript_in_context run_context, string

    run_with_context = (run_context, fn) ->
      output_cell = run_context.output_cell
      has_pending = run_context.pending.map (n) -> n > 0
      # FIXME not sure why this is necessary; seems like a bug in Bacon
      # without it, the skipWhile seems to be ignored
      has_pending.subscribe ->
      # a cell is "done enough" if there were no async tasks,
      # or when the first async task completes
      no_longer_pending = run_context.changes.skipWhile(has_pending)
      output_cell.done = no_longer_pending.take(1).map -> output_cell
      fn()

      # FIXME since render isn't called, there's never a "changes" event, so scrolling never happens
      output_cell.component.set_component run_context.component_list

    create_bare_output_cell_and_context = (notebook) ->
      output_cell = create_output_cell notebook
      run_context = context.create_run_context [create_input_context(notebook), {output_cell}, create_notebook_run_context(output_cell)]
      insert_cell output_cell
      run_context

    eval_coffeescript_without_input_cell = (notebook, string) ->
      run_context = create_bare_output_cell_and_context notebook
      eval_coffeescript_into_output_cell run_context, string

    run_without_input_cell = (notebook, fn) ->
      run_context = create_bare_output_cell_and_context notebook
      run_with_context run_context, ->
        context.run_in_context run_context, fn

    create_input_context = (notebook) ->
      context.create_context notebook.base_context

    create_notebook_run_context = (cell) ->
      notebook = cell.notebook
      run_context =
        notebook: notebook
        # TODO rename
        set_code: (code) ->
          # TODO coffeescript
          cell = add_input_cell notebook, after: run_context.output_cell
          set_cell_value cell, code
          focus_cell cell
        run: (code) ->
          # TODO coffeescript
          cell = add_input_cell notebook, after: run_context.output_cell
          set_cell_value cell, code
          run cell
        # TODO does it make sense to use output cells here?
        previously_run: -> input_cell_at_offset(cell, -1).editor.getValue()
        export_notebook: -> export_notebook cell
        get_input_value: (number) ->
          get_input_cell_by_number(notebook, number)?.editor.getValue()

    open_file_picker = (run_context) ->
      run_context.notebook.opening_run_context = run_context
      run_context.notebook.$file_picker.trigger 'click'

    handle_file = (run_context, file, options={}) ->
      if file.type.indexOf('image') < 0
        [prefix..., extension] = file.filename.split '.'
        if extension is 'coffee'
          cell = add_input_cell run_context.notebook, after: run_context.output_cell
          # TODO cell type
          set_cell_value cell, file.content
          if options.run
            run cell
        else if extension is 'md'
          run_without_input_cell run_context.notebook, ->
            @md file.content
        else
          try
            imported = JSON.parse file.content
          catch e
            run_context.fns.error "File #{file.filename} isn't a lead.js notebook:\n#{e}"
            return
          version = imported.lead_js_version
          unless version?
            run_context.fns.error "File #{file.filename} isn't a lead.js notebook"
            return
          import_notebook run_context.notebook, run_context.output_cell, imported, options

    load_file = (run_context, file) ->
      if file.type.indexOf('image') < 0
        reader = new FileReader
        reader.onload = (e) ->
          handle_file run_context,
            filename: file.name
            content: e.target.result
            type: file.type

        reader.readAsText file

    save = (input_cell) ->
      text = JSON.stringify export_notebook input_cell
      blob = new Blob [text], type: notebook_content_type
      link = document.createElement 'a'
      link.innerHTML = 'Download Notebook'
      link.href = window.webkitURL.createObjectURL blob
      link.download = 'notebook.lnb'
      link.click()
      link

    exports = {
      create_notebook
      input_cell_at_offset
      init_codemirror
      add_input_cell
      remove_cell
      focus_cell
      eval_coffeescript_without_input_cell
      run_without_input_cell
      set_cell_value

      run: (cell, opts={advance: true}) ->
        output_cell = run cell
        if opts.advance
          new_cell = add_input_cell cell.notebook, after: output_cell, reuse: true
          focus_cell new_cell

      handle_file: handle_file

      save: (cell) ->
        eval_coffeescript_before cell, 'save'

      context_help: (cell, token) ->
        if graphite.has_docs token
          eval_coffeescript_before cell, "docs '#{token}'"
        else if cell.context.imported_context_fns[token]?
          eval_coffeescript_before cell, "help #{token}"

      move_focus: (cell, offset) ->
        new_cell = input_cell_at_offset cell, offset
        if new_cell?
          focus_cell new_cell
          true
        else
          false

      cell_value: (cell) ->
        cell.editor.getValue()
    }

    exports
