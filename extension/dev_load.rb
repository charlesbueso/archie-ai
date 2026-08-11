# Development hot-loader. From the Ruby console (or eval_ruby on the old
# bridge): load "B:/repos/archie-ai/extension/dev_load.rb"
# Re-loads every source file and restarts the server on the configured port
# (override first with: $archie_dev_port = 9877).
base = File.join(File.dirname(__FILE__), 'archie_mcp')
%w[config util introspect edit versioning server].each do |f|
  load File.join(base, f + '.rb')
end

Archie::Server.stop if Archie::Server.running?
port = defined?($archie_dev_port) && $archie_dev_port ? $archie_dev_port : nil
srv = Archie::Server.start(port)
"archie dev server v#{Archie::Server::VERSION} on port #{srv.port}"
