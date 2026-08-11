# File-level primitives for the Python side's versioning layer.
# save_copy captures the CURRENT IN-MEMORY state without touching the working
# file — that is what makes snapshots safe on a model with unsaved changes.
require 'fileutils'
require_relative 'util'

module Archie
  module Versioning
    # Monotonic edit counter — the snapshot dedup key. Model#guid does NOT
    # change on edits (verified, SU2025) and save_copy re-serializes so its
    # bytes differ even for an untouched model, so neither can be the key.
    #
    # BUG-01: the observer instances MUST be kept referenced from Ruby.
    # `model.add_observer(EditCounter.new)` lets the instance be garbage
    # collected, after which the callbacks silently stop firing forever —
    # seq froze at 1 and every snapshot deduped against the first one,
    # disabling the entire safety net. @observers holds them alive.
    #
    # Defence in depth: our own mutating tools also call bump! directly, so
    # snapshot correctness never depends solely on the observer surviving.
    # The observer exists to catch edits the USER makes in SketchUp's UI.
    @seq = 0 unless defined?(@seq) && @seq
    @observers = {} unless defined?(@observers) && @observers
    @app_hooked = false unless defined?(@app_hooked) && @app_hooked

    class EditCounter < Sketchup::ModelObserver
      def onTransactionCommit(_m); Archie::Versioning.bump!; end
      def onTransactionUndo(_m);   Archie::Versioning.bump!; end
      def onTransactionRedo(_m);   Archie::Versioning.bump!; end
    end

    class AppWatcher < Sketchup::AppObserver
      def onOpenModel(m); Archie::Versioning.watch(m); end
      def onNewModel(m);  Archie::Versioning.watch(m); end
      def expectsStartupModelNotifications; true; end
    end

    def self.bump!
      @seq = seq + 1
    end

    def self.seq
      @seq || 0
    end

    def self.observer_alive?
      m = Sketchup.active_model
      m ? !@observers[m.object_id].nil? : false
    end

    def self.watch(model)
      key = model.object_id
      return if @observers[key]
      obs = EditCounter.new
      model.add_observer(obs)
      @observers[key] = obs # keep the reference alive; see BUG-01 above
      bump! # a newly opened model is a state change by definition
    end

    def self.get_model_ref(_params)
      m = Sketchup.active_model
      watch(m) # belt and braces: never report a seq for an unwatched model
      {
        'path' => m.path.to_s,
        'title' => m.title.to_s,
        'modified' => m.modified?,
        'edit_seq' => seq,
        'observer_alive' => observer_alive?,
        'sketchup' => Sketchup.version,
        'ruby' => RUBY_VERSION
      }
    end

    def self.hook_app
      return if @app_hooked
      @app_observer = AppWatcher.new
      Sketchup.add_observer(@app_observer)
      @app_hooked = true
    end

    def self.save_copy(params)
      path = params.fetch('path')
      FileUtils.mkdir_p(File.dirname(path))
      m = Sketchup.active_model
      ok = m.save_copy(path)
      raise "save_copy failed for #{path}" unless ok && File.exist?(path)
      { 'path' => path, 'bytes' => File.size(path) }
    end

    def self.save_model(_params)
      m = Sketchup.active_model
      raise 'model has no path yet; use SketchUp Save As first' if m.path.to_s.empty?
      ok = m.save
      { 'saved' => ok, 'path' => m.path.to_s }
    end

    # BUG-10: reopening a model with unsaved edits pops SketchUp's modal
    # "Save changes?" dialog and blocks until a human clicks. In the natural
    # try -> restore -> try loop that fires constantly and breaks the promise
    # of automation. Marking the model unmodified first suppresses it — safe
    # here because every caller has already taken a snapshot of that state.
    def self.open_model(params)
      path = params.fetch('path')
      raise "file not found: #{path}" unless File.exist?(path)
      discarded = false
      if params.fetch('discard_unsaved', false)
        m = Sketchup.active_model
        if m && m.modified?
          # set_datum is a no-op write that lets us clear the dirty flag
          m.set_attribute('archie', 'discard_marker', Time.now.to_i)
          begin
            m.modified = false
            discarded = true
          rescue StandardError
            # older APIs: fall back to letting SketchUp prompt
            discarded = false
          end
        end
      end
      ok = Sketchup.open_file(path)
      { 'opened' => ok, 'path' => path, 'discarded_unsaved' => discarded }
    end
  end
end
