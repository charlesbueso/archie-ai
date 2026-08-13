# Creation primitives: box, slab, wall, opening.
#
# Deliberately primitives rather than high-level generators. A pool, a planter,
# a parapet or a massing study are all compositions of these, so the agent can
# improvise arrangements nobody hard-coded — whereas a create_pool() with
# fifteen parameters only ever makes the pool its author imagined.
#
# Every creator: validates in METRES, wraps one undo operation, verifies the
# result geometrically, and rolls back if the verification fails.
require_relative 'util'
require_relative 'introspect'
require_relative 'versioning'

module Archie
  module Create
    MAX_DIM = 500.0 # m — beyond this it is a units mistake, not a building

    def self.check_size(size, what)
      3.times do |i|
        v = size[i].to_f
        unless v.positive?
          raise "#{what}: size must be > 0 on every axis (axis #{%w[x y z][i]} got #{v}). " \
                'All dimensions are in METRES.'
        end
        if v > MAX_DIM
          raise "#{what}: #{v}m on axis #{%w[x y z][i]} exceeds #{MAX_DIM}m — check the units."
        end
      end
    end

    # Extrude a horizontal rectangle upward into a named group.
    def self.rect_prism(ents, corners_xy, z_bottom, height, name)
      pts = corners_xy.map { |x, y| Geom::Point3d.new(Util.to_in(x), Util.to_in(y), Util.to_in(z_bottom)) }
      grp = ents.add_group
      face = grp.entities.add_face(pts)
      raise 'could not create the base face (degenerate or self-intersecting outline)' if face.nil?
      # pushpull follows the face normal; make sure we build upward
      face.reverse! if face.normal.z < 0
      face.pushpull(Util.to_in(height))
      grp.name = name if name && !name.to_s.empty?
      grp
    end

    # Cut a rectangular hole straight through a wall container.
    # Shared by create_opening and merge_openings — merging is just cutting
    # away the mullion strips between existing openings.
    # h_axis = the wall's in-plane horizontal axis (0=x, 1=y); n_axis = its normal.
    # face_n / thickness may be supplied explicitly — required for the model
    # root, whose bbox is the whole building rather than one wall.
    def self.cut_rect(cont, h_axis, n_axis, h0, h1, z0, z1, face_n = nil, thickness = nil)
      if face_n.nil? || thickness.nil?
        raise 'cut_rect needs an explicit plane for root-level geometry' if cont[:root]
        bb = Util.world_bbox_live(cont[:entity], cont[:transform])
        face_n ||= bb[:min][n_axis]
        thickness ||= bb[:size][n_axis]
      end
      inv = cont[:transform].inverse
      corners = [[h0, z0], [h1, z0], [h1, z1], [h0, z1]].map do |h, z|
        w = [0.0, 0.0, 0.0]
        w[h_axis] = h
        w[n_axis] = face_n
        w[2] = z
        Util.pt(w, inv)
      end
      face = Util.ents_of(cont).add_face(corners)
      return false if face.nil?
      dir = Geom::Vector3d.new(n_axis.zero? ? 1 : 0, n_axis == 1 ? 1 : 0, 0)
      depth = face.normal.dot(dir) > 0 ? -thickness : thickness
      face.pushpull(Util.to_in(depth))
      true
    end

    def self.finish(model, grp, op_flag, expect_size, label)
      bb = Util.world_bbox_live(grp, grp.transformation)
      3.times do |i|
        next unless expect_size[i]
        if (bb[:size][i] - expect_size[i].to_f).abs > 0.01
          model.abort_operation
          Versioning.bump!
          raise "#{label} failed verification and was ROLLED BACK (nothing added). " \
                "Axis #{%w[x y z][i]}: wanted #{expect_size[i]}m, got #{bb[:size][i]}m."
        end
      end
      model.commit_operation
      Versioning.bump!
      { 'pid' => grp.persistent_id, 'name' => grp.name.to_s,
        'min' => bb[:min], 'size' => bb[:size], 'verified' => true,
        'note' => 'created at model root; use transform_component to move it, ' \
                  'or locate to show the user where it landed' }
    end

    def self.box(params)
      model = Sketchup.active_model
      origin = params.fetch('origin')
      size = params.fetch('size')
      check_size(size, 'create_box')
      name = params['name'] || 'ARCHIE_BOX'
      x, y, z = origin.map(&:to_f)
      dx, dy, dz = size.map(&:to_f)
      op = false
      begin
        model.start_operation('Archie: create box', true)
        op = true
        grp = rect_prism(model.entities,
                         [[x, y], [x + dx, y], [x + dx, y + dy], [x, y + dy]],
                         z, dz, name)
        finish(model, grp, op, [dx, dy, dz], 'create_box')
      rescue StandardError => e
        model.abort_operation if op && !e.message.include?('ROLLED BACK')
        raise e
      end
    end

    # A slab is a box positioned by the level it serves. datum='top' means
    # z_level is the finished floor and the slab hangs below it (the usual
    # architectural reading); datum='bottom' means it sits on z_level.
    def self.slab(params)
      model = Sketchup.active_model
      origin = params.fetch('origin')      # [x, y]
      size = params.fetch('size')          # [dx, dy]
      thickness = params.fetch('thickness').to_f
      z_level = params.fetch('z_level').to_f
      datum = params.fetch('datum', 'top')
      raise "datum must be 'top' or 'bottom'" unless %w[top bottom].include?(datum)
      check_size([size[0], size[1], thickness], 'create_slab')
      name = params['name'] || 'ARCHIE_SLAB'
      x, y = origin.map(&:to_f)
      dx, dy = size.map(&:to_f)
      z_bottom = datum == 'top' ? z_level - thickness : z_level
      op = false
      begin
        model.start_operation('Archie: create slab', true)
        op = true
        grp = rect_prism(model.entities,
                         [[x, y], [x + dx, y], [x + dx, y + dy], [x, y + dy]],
                         z_bottom, thickness, name)
        res = finish(model, grp, op, [dx, dy, thickness], 'create_slab')
        res.merge('z_bottom' => Util.r(z_bottom), 'z_top' => Util.r(z_bottom + thickness),
                  'datum' => datum)
      rescue StandardError => e
        model.abort_operation if op && !e.message.include?('ROLLED BACK')
        raise e
      end
    end

    # A wall runs between two points in plan and is centred on that line, so
    # any orientation works — not just axis-aligned.
    def self.wall(params)
      model = Sketchup.active_model
      a = params.fetch('start')
      b = params.fetch('end')
      height = params.fetch('height').to_f
      thickness = params.fetch('thickness', 0.15).to_f
      z_base = params.fetch('z_base', 0.0).to_f
      name = params['name'] || 'ARCHIE_WALL'
      ax, ay = a.map(&:to_f)
      bx, by = b.map(&:to_f)
      len = Math.sqrt((bx - ax)**2 + (by - ay)**2)
      raise 'create_wall: start and end are the same point' if len < 1e-6
      check_size([len, thickness, height], 'create_wall')

      ux = (bx - ax) / len
      uy = (by - ay) / len
      px = -uy * (thickness / 2.0)  # perpendicular offset
      py = ux * (thickness / 2.0)
      corners = [[ax + px, ay + py], [bx + px, by + py],
                 [bx - px, by - py], [ax - px, ay - py]]
      op = false
      begin
        model.start_operation('Archie: create wall', true)
        op = true
        grp = rect_prism(model.entities, corners, z_base, height, name)
        bb = Util.world_bbox(grp, grp.transformation)
        if (bb[:size][2] - height).abs > 0.01
          model.abort_operation
          Versioning.bump!
          raise "create_wall failed verification and was ROLLED BACK (nothing added). " \
                "Height wanted #{height}m, got #{bb[:size][2]}m."
        end
        model.commit_operation
        Versioning.bump!
        { 'pid' => grp.persistent_id, 'name' => grp.name.to_s,
          'min' => bb[:min], 'size' => bb[:size],
          'length' => Util.r(len), 'thickness' => thickness, 'height' => height,
          'verified' => true }
      rescue StandardError => e
        model.abort_operation if op && !e.message.include?('ROLLED BACK')
        raise e
      end
    end

    # Cut a NEW door/window through an existing wall.
    # Works on axis-aligned walls (same constraint as resize_opening).
    # `position` is the opening's centre measured along the wall from its
    # lower coordinate end; `sill` is measured from the wall's own base.
    def self.opening(params)
      model = Sketchup.active_model
      pid = params.fetch('wall_pid').to_i
      width = params.fetch('width').to_f
      height = params.fetch('height').to_f
      sill = params.fetch('sill', 0.0).to_f
      position = params['position']
      auto_unique = params.fetch('auto_unique', true)
      raise 'width must be > 0' unless width.positive?
      raise 'height must be > 0' unless height.positive?
      raise 'sill must be >= 0' if sill.negative?

      cont, unique_report = Edit.editable_container(model, pid, auto_unique)
      if cont[:root]
        raise 'create_opening needs a specific wall container, not the model root. ' \
              'Loose root geometry has no single wall to cut through.'
      end
      bb = Util.cont_bbox(cont)
      dx, dy, dz = bb[:size]
      raise "container #{pid} is not wall-like (no vertical extent)" if dz < 0.3

      # thin horizontal axis = the wall's normal
      if dx <= dy
        n_axis = 0; h_axis = 1
      else
        n_axis = 1; h_axis = 0
      end
      thickness = bb[:size][n_axis]
      wall_len = bb[:size][h_axis]
      raise "container #{pid} is not wall-like (#{Util.r(thickness)}m thick)" if thickness > 1.5
      if width > wall_len - 0.02
        raise "opening #{width}m is wider than the wall (#{Util.r(wall_len)}m). " \
              "The widest that fits is about #{Util.r(wall_len - 0.1)}m."
      end
      if sill + height > dz + 0.001
        raise "sill #{sill}m + height #{height}m exceeds the wall height (#{Util.r(dz)}m). " \
              "The tallest that fits at this sill is #{Util.r(dz - sill)}m."
      end

      centre = position.nil? ? wall_len / 2.0 : position.to_f
      h0 = bb[:min][h_axis] + centre - width / 2.0
      h1 = h0 + width
      if h0 < bb[:min][h_axis] - 1e-6 || h1 > bb[:max][h_axis] + 1e-6
        raise "an opening #{width}m wide centred #{centre}m along the wall would run off " \
              "the end. Keep the centre between #{Util.r(width / 2.0)}m and " \
              "#{Util.r(wall_len - width / 2.0)}m."
      end
      z0 = bb[:min][2] + sill
      z1 = z0 + height

      op = false
      begin
        model.start_operation('Archie: create opening', true)
        op = true
        unless cut_rect(cont, h_axis, n_axis, h0, h1, z0, z1)
          raise 'could not draw the opening outline on the wall face'
        end

        slab_list = Introspect.slabs(model)
        ffls = Introspect.storeys(slab_list).map { |s| s['ffl_z'] }
        fresh = Util.find_container(model, cont[:pid]) || cont
        made = Introspect.openings_of(fresh, ffls).min_by do |o|
          p = o[:cluster][:primary]
          (p[:w] - width).abs + (p[:h] - height).abs
        end
        ok = made && (made[:cluster][:primary][:w] - width).abs < 0.02 &&
             (made[:cluster][:primary][:h] - height).abs < 0.02
        unless ok
          model.abort_operation
          Versioning.bump!
          got = made ? "#{Util.r(made[:cluster][:primary][:w], 2)} x " \
                       "#{Util.r(made[:cluster][:primary][:h], 2)}" : 'nothing'
          raise "create_opening failed verification and was ROLLED BACK (wall unchanged). " \
                "Wanted #{width} x #{height}, found #{got}. The wall may not be a clean " \
                'solid, or the outline may have merged with existing geometry.'
        end
        model.commit_operation
        Versioning.bump!
        out = { 'wall_pid' => fresh[:pid],
                'opening_id' => Introspect.opening_id(fresh, made[:cluster][:primary], made[:cluster]),
                'kind' => made[:kind],
                'width' => Util.r(made[:cluster][:primary][:w], 3),
                'height' => Util.r(made[:cluster][:primary][:h], 3),
                'sill_above_wall_base' => Util.r(sill, 3),
                'verified' => true }
        out['made_unique'] = unique_report if unique_report
        out
      rescue StandardError => e
        model.abort_operation if op && !e.message.include?('ROLLED BACK')
        raise e
      end
    end
  end
end
