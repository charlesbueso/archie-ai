# Archie MCP — SketchUp extension registrar.
# Install: copy archie_mcp.rb + archie_mcp/ into the SketchUp Plugins folder
# (that is exactly what the .rbz built by tools/build.py contains).
require 'sketchup.rb'
require 'extensions.rb'

module Archie
  unless file_loaded?(__FILE__)
    ex = SketchupExtension.new('Archie MCP', 'archie_mcp/main')
    ex.description = 'Typed MCP bridge for architectural editing with Claude. ' \
                     'Introspection, opening edits, slab edits, versioning.'
    ex.version     = '0.4.1'
    ex.creator     = 'Archie'
    Sketchup.register_extension(ex, true)
    file_loaded(__FILE__)
  end
end
