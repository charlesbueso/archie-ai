# Shared configuration. Single source of truth is ~/Archie/config.json —
# both the Ruby extension and the Python MCP server read the same file, so
# the two halves can never disagree about the port.
require 'json'

module Archie
  module Config
    DEFAULTS = {
      'port'       => 9876,
      'host'       => '127.0.0.1',
      'autostart'  => true,
      'dev_mode'   => false,   # gates eval_ruby
      'log_dir'    => nil
    }.freeze

    def self.home
      env = ENV['ARCHIE_HOME']
      return env if env && !env.empty?
      File.join(File.expand_path('~'), 'Archie')
    end

    def self.path
      File.join(home, 'config.json')
    end

    def self.load
      cfg = {}
      DEFAULTS.each { |k, v| cfg[k] = v }
      begin
        if File.exist?(path)
          data = JSON.parse(File.read(path))
          cfg.merge!(data) if data.is_a?(Hash)
        end
      rescue StandardError => e
        puts "[archie] config read error: #{e.message}"
      end
      cfg
    end
  end
end
