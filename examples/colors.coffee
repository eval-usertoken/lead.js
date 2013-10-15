colors = require 'colors'
output = []
for name, variations of colors.brewer
  output.push "<h3>#{name}</h3>"
  for size, colors of variations
    output.push "<h4 style='margin-top: 1em'>#{size}</h4>"
    for color in colors
      output.push "<span style='background-color: #{color}; padding: 5px; display: inline-block;'>#{color}</span> "

html output.join ''
