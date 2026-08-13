# NDJSON-over-TCP server, replacing upstream sketchup-mcp's
# one-request-per-connection socket (the source of its stale-first-response
# bug). Persistent connections; every request gets exactly one reply.
#
# Concurrency model: a UI.start_timer pump accepts sockets and services
# pending lines on the SketchUp main thread — required anyway, since the
# model API must be driven from the main thread.
require 'socket'
require 'json'
require_relative 'config'
require_relative 'introspect'
require_relative 'edit'
require_relative 'create'
require_relative 'versioning'

module Archie
  class Server
    VERSION = '0.4.0'.freeze

    @instance = nil
    class << self
      attr_accessor :instance
    end

    def self.running?
      !@instance.nil?
    end

    def self.start(port = nil)
      stop if running?
      cfg = Config.load
      port ||= cfg['port']
      s = Server.new(cfg, port.to_i)
      s.start
      @instance = s
      s
    end

    def self.stop
      return unless @instance
      @instance.stop
      @instance = nil
    end

    attr_reader :port

    def initialize(cfg, port)
      @cfg = cfg
      @port = port
      @clients = []
      @buffers = {}
      @timer = nil
      @tcp = nil
    end

    def start
      Versioning.hook_app
      Versioning.watch(Sketchup.active_model) if Sketchup.active_model
      @tcp = TCPServer.new(@cfg['host'] || '127.0.0.1', @port)
      @timer = UI.start_timer(0.1, true) { tick }
      puts "[archie] server v#{VERSION} listening on #{@cfg['host']}:#{@port} (dev_mode=#{@cfg['dev_mode']})"
    end

    def stop
      UI.stop_timer(@timer) if @timer
      @timer = nil
      @clients.each { |c| c.close rescue nil }
      @clients.clear
      @buffers.clear
      @tcp.close rescue nil
      @tcp = nil
      puts '[archie] server stopped'
    end

    def tick
      accept_new
      service_clients
    rescue StandardError => e
      puts "[archie] tick error: #{e.class}: #{e.message}"
    end

    def accept_new
      loop do
        sock = @tcp.accept_nonblock
        sock.sync = true
        @clients << sock
        @buffers[sock] = +''
      end
    rescue IO::WaitReadable, Errno::EWOULDBLOCK, Errno::EAGAIN
      nil
    end

    def service_clients
      @clients.dup.each do |sock|
        begin
          data = sock.read_nonblock(1_048_576)
          @buffers[sock] << data
          while (nl = @buffers[sock].index("\n"))
            line = @buffers[sock].slice!(0..nl).strip
            handle_line(sock, line) unless line.empty?
          end
        rescue IO::WaitReadable, Errno::EWOULDBLOCK, Errno::EAGAIN
          next
        rescue EOFError, Errno::ECONNRESET, Errno::ECONNABORTED, IOError
          drop(sock)
        end
      end
    end

    def drop(sock)
      @clients.delete(sock)
      @buffers.delete(sock)
      sock.close rescue nil
    end

    def handle_line(sock, line)
      id = nil
      begin
        req = JSON.parse(line)
        id = req['id']
        method = req['method'].to_s
        params = req['params'] || {}
        result = dispatch(method, params)
        reply(sock, 'id' => id, 'result' => result)
      rescue StandardError => e
        reply(sock, 'id' => id, 'error' => { 'message' => e.message, 'type' => e.class.to_s })
      end
    end

    def reply(sock, payload)
      sock.write(JSON.generate(payload) + "\n")
    rescue StandardError
      drop(sock)
    end

    def dispatch(method, params)
      case method
      when 'ping'
        { 'pong' => true, 'version' => VERSION, 'sketchup' => Sketchup.version }
      when 'archie_info'
        cfg = Config.load
        { 'version' => VERSION, 'port' => @port, 'dev_mode' => !!cfg['dev_mode'],
          'sketchup' => Sketchup.version, 'ruby' => RUBY_VERSION }
      when 'get_model_info'   then Introspect.get_model_info(params)
      when 'list_openings'    then Introspect.list_openings(params)
      when 'get_selection'    then Introspect.get_selection(params)
      when 'locate'           then Introspect.locate(params)
      when 'resize_opening'   then Edit.resize_opening(params)
      when 'set_slab_thickness' then Edit.set_slab_thickness(params)
      when 'make_unique'      then Edit.make_unique(params)
      when 'merge_openings'   then Edit.merge_openings(params)
      when 'transform_component' then Edit.transform_component(params)
      when 'create_box'       then Create.box(params)
      when 'create_slab'      then Create.slab(params)
      when 'create_wall'      then Create.wall(params)
      when 'create_opening'   then Create.opening(params)
      when 'get_model_ref'    then Versioning.get_model_ref(params)
      when 'save_copy'        then Versioning.save_copy(params)
      when 'save_model'       then Versioning.save_model(params)
      when 'open_model'       then Versioning.open_model(params)
      when 'eval_ruby'        then eval_ruby(params)
      else
        raise "unknown method #{method.inspect}"
      end
    end

    # Arbitrary code execution — gated. Fine for the developer's own machine;
    # off by default for beta users (config.json dev_mode:false).
    def eval_ruby(params)
      cfg = Config.load
      unless cfg['dev_mode']
        raise 'eval_ruby is disabled (dev_mode is off in ~/Archie/config.json)'
      end
      code = params.fetch('code')
      value = eval(code) # rubocop:disable Security/Eval -- explicit dev-mode feature
      { 'result' => value.to_s[0, 20_000] }
    end
  end
end
