# Archie MCP bootstrap: menu items + autostart.
require 'sketchup.rb'
require_relative 'config'
require_relative 'server'

module Archie
  def self.status_message
    if Server.running?
      "Archie MCP v#{Server::VERSION} running on port #{Server.instance.port}"
    else
      'Archie MCP is stopped'
    end
  end

  unless defined?(@menu_installed) && @menu_installed
    menu = UI.menu('Plugins').add_submenu('Archie')
    menu.add_item('Start Server') { Server.start }
    menu.add_item('Stop Server')  { Server.stop }
    menu.add_item('Status')       { UI.messagebox(status_message) }
    @menu_installed = true
  end

  # Autostart fixes the #1 support issue with the old bridge ("server not
  # started"). Deferred a moment so SketchUp finishes loading first.
  cfg = Config.load
  if cfg['autostart'] && !Server.running?
    UI.start_timer(1.0, false) do
      begin
        Server.start unless Server.running?
      rescue StandardError => e
        puts "[archie] autostart failed: #{e.message}"
      end
    end
  end
end
