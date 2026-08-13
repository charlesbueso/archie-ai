# Mutating tools: resize_opening, set_slab_thickness.
#
# Hard-won rules encoded here (each one broke a live edit before it was a rule):
# 1. Vertices move in ONE transform_by_vectors call per Entities collection.
#    Sequential transform_entities calls leave reveal faces transiently
#    non-planar; SketchUp splits and heals them and the opening is destroyed.
# 2. Vertices are selected by REGION (a box around the opening), not by loop
#    membership — stepped frames carry vertices *between* the loops, and
#    missing them tears the face.
# 3. Region margins are clamped against sibling openings so a mullion 5cm
#    away is never dragged along (min(0.08, gap*0.45) per side).
# 4. Per-vertex deltas are clamped to the container's own shell so a sill
#    lowered to floor level collapses cleanly onto the wall bottom instead of
#    punching a hidden lip below it.
# 5. Shared (instanced) geometry is refused — editing it would change every
#    occurrence in the model.
# 6. BUG-02: verification runs INSIDE the operation. If the achieved geometry
#    does not match the request, abort_operation rolls the model back and the
#    tool raises. A mutation never survives its own failed verification.
require_relative 'util'
require_relative 'introspect'
require_relative 'versioning'

module Archie
  module Edit
    BASE_MARGIN = 0.08
    MIN_MARGIN  = 0.005
    NORM_MARGIN = 0.06
    TOL         = 0.015 # m, verification tolerance

    MAX_SLAB_THICKNESS = 3.0  # m — beyond this it is a data-entry error
    MAX_OPENING_DIM    = 20.0 # m

    def self.parse_id(id)
      pid_s, center_s = id.to_s.split(':', 2)
      raise ArgumentError, "bad opening id #{id.inspect} (want 'pid:x,y,z')" unless center_s
      cx, cy, cz = center_s.split(',').map(&:to_f)
      [pid_s.to_i, cx, cy, cz]
    end

    def self.guard_editable(cont)
      return unless cont[:shared]
      raise "container #{cont[:pid]} (#{cont[:path]}) is shared geometry — its definition " \
            'or an ancestor is instanced more than once, so editing it would change every ' \
            'occurrence in the model. Call make_unique first, or pass auto_unique: true.'
    end

    # Make an instance independently editable by uniquifying every level of
    # its ancestor chain that is instanced more than once.
    #
    # Downloaded/library models are almost entirely component instances — in
    # one real session 5 of 5 slabs were uneditable — so without this the
    # typed tools have nothing to act on.
    #
    # Returns the entity's NEW pid: copying a definition re-issues persistent
    # ids for everything inside it, so the caller's old pid is dead.
    MAX_SUBTREE_UNIQUE = 400

    # Uniquify everything INSIDE a container too. Making a node unique only
    # gives it its own definition — the children in that definition are still
    # instances shared with the original's children, so an edit reaching into
    # nested geometry would still leak into the other copies. Slabs in library
    # models are routinely built this way.
    def self.uniquify_subtree(entity, acc, depth = 0, max_depth = 6)
      return acc if depth >= max_depth || acc.length >= MAX_SUBTREE_UNIQUE
      entity.definition.entities.to_a.each do |e|
        break if acc.length >= MAX_SUBTREE_UNIQUE
        next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        inst = e.definition.count_instances
        if inst > 1
          was = e.definition.name
          e.make_unique
          acc << { 'level' => was, 'was_instances' => inst,
                   'siblings_left_untouched' => inst - 1, 'nested' => true }
        end
        uniquify_subtree(e, acc, depth + 1, max_depth)
      end
      acc
    end

    def self.make_unique(params)
      model = Sketchup.active_model
      pid = params.fetch('pid').to_i
      deep = params.fetch('deep', true)
      idx = Util.index_path(model, pid)
      raise "pid #{pid} not found in this model" unless idx

      op = false
      begin
        model.start_operation('Archie: make unique', true)
        op = true
        cur = model.entities
        node = nil
        steps = []
        idx.each do |i|
          node = cur.to_a[i]
          raise 'geometry changed while making unique; re-run the listing' if node.nil?
          inst = node.definition.count_instances
          if inst > 1
            was = node.definition.name
            node.make_unique
            steps << { 'level' => was, 'was_instances' => inst,
                       'siblings_left_untouched' => inst - 1, 'nested' => false }
          end
          cur = node.definition.entities
        end
        nested = deep ? uniquify_subtree(node, []) : []
        model.commit_operation
        op = false
        Versioning.bump!
        {
          'old_pid' => pid, 'new_pid' => node.persistent_id,
          'levels_uniquified' => steps + nested,
          'ancestors_uniquified' => steps.length,
          'nested_uniquified' => nested.length,
          'already_unique' => steps.empty? && nested.empty?,
          'truncated' => nested.length >= MAX_SUBTREE_UNIQUE,
          'note' => (steps.empty? && nested.empty?) ? 'this geometry was already independent' :
            'this instance is now independent; the other copies keep their original form'
        }
      rescue StandardError => e
        model.abort_operation if op
        raise e
      end
    end

    # Resolve a pid to an editable container, uniquifying it first when asked.
    # Returns [container, unique_report_or_nil].
    def self.editable_container(model, pid, auto_unique)
      cont = Util.find_container(model, pid)
      raise "container pid #{pid} not found in this model" unless cont
      return [cont, nil] unless cont[:shared]
      unless auto_unique
        guard_editable(cont)
      end
      report = make_unique('pid' => pid)
      fresh = Util.find_container(model, report['new_pid'])
      raise 'lost track of the geometry after make_unique' unless fresh
      [fresh, report]
    end

    ANCHORS = %w[min center max].freeze

    # Move / scale / resize ANY container — the general-purpose tool for
    # geometry that is neither an opening nor a slab (ledges, sills, furniture,
    # massing blocks). `set_size` with a per-axis anchor is what makes
    # "make this ledge stick out further" expressible: anchor the wall side,
    # grow the other.
    def self.transform_component(params)
      model = Sketchup.active_model
      pid = params.fetch('pid').to_i
      auto_unique = params.fetch('auto_unique', true)
      move = params['move']
      scale = params['scale']
      set_size = params['set_size']
      anchor = params.fetch('anchor', 'center')
      unless move || scale || set_size
        raise 'pass at least one of move, scale or set_size'
      end

      anchors = anchor.is_a?(Array) ? anchor : [anchor, anchor, anchor]
      anchors.each do |a|
        raise "anchor must be one of #{ANCHORS.join(', ')} (got #{a.inspect})" unless ANCHORS.include?(a.to_s)
      end

      cont, unique_report = editable_container(model, pid, auto_unique)
      bb = Util.world_bbox(cont[:entity], cont[:transform])
      before = { 'min' => bb[:min], 'size' => bb[:size] }

      factors = [1.0, 1.0, 1.0]
      if scale
        3.times { |i| factors[i] = scale[i].to_f if scale[i] && scale[i].to_f.positive? }
      end
      if set_size
        3.times do |i|
          next unless set_size[i]
          want = set_size[i].to_f
          raise "set_size values must be > 0 (axis #{i} got #{want})" unless want.positive?
          cur = bb[:size][i]
          if cur < 1e-6
            raise "cannot resize axis #{%w[x y z][i]}: the component is flat there " \
                  "(size #{cur}m). Use move, or scale a different axis."
          end
          factors[i] = want / cur
        end
      end
      factors.each_with_index do |f, i|
        if f > 1000 || f < 0.001
          raise "refusing an extreme scale on axis #{%w[x y z][i]} (factor #{Util.r(f, 4)}). " \
                'Check the units — all sizes are in METRES.'
        end
      end

      anchor_world = 3.times.map do |i|
        case anchors[i].to_s
        when 'min' then bb[:min][i]
        when 'max' then bb[:max][i]
        else (bb[:min][i] + bb[:max][i]) / 2.0
        end
      end

      pinv = Util.parent_transform(cont).inverse
      op = false
      begin
        model.start_operation('Archie: transform component', true)
        op = true
        if factors != [1.0, 1.0, 1.0]
          ap = Util.pt(anchor_world, pinv)
          cont[:entity].transform!(
            Geom::Transformation.scaling(ap, factors[0], factors[1], factors[2]))
        end
        if move
          p0 = Util.pt([0, 0, 0], pinv)
          p1 = Util.pt([move[0].to_f, move[1].to_f, move[2].to_f], pinv)
          cont[:entity].transform!(Geom::Transformation.translation(p1 - p0))
        end
        # transform! changes the entity's OWN transformation, so the world
        # transform captured before the edit is stale — re-resolve it before
        # measuring. (Vertex-moving edits like slabs don't have this problem.)
        fresh = Util.find_container(model, cont[:pid]) || cont
        nb = Util.world_bbox_live(fresh[:entity], fresh[:transform])
        if set_size
          3.times do |i|
            next unless set_size[i]
            if (nb[:size][i] - set_size[i].to_f).abs > 0.01
              model.abort_operation
              op = false
              Versioning.bump!
              raise "transform failed verification and was ROLLED BACK (model unchanged). " \
                    "Axis #{%w[x y z][i]} wanted #{set_size[i]}m, got #{nb[:size][i]}m."
            end
          end
        end
        model.commit_operation
        op = false
        Versioning.bump!
        out = { 'pid' => cont[:pid], 'path' => cont[:path],
                'before' => before, 'after' => { 'min' => nb[:min], 'size' => nb[:size] },
                'anchor' => anchors, 'verified' => true }
        out['made_unique'] = unique_report if unique_report
        out
      rescue StandardError => e
        if op
          model.abort_operation
          Versioning.bump!
        end
        raise e
      end
    end

    # Uses Introspect.openings_of so kind/clustering are IDENTICAL to what
    # list_openings reported (BUG-05: these used to disagree because the two
    # call sites clustered with different minimum sizes).
    def self.find_opening(model, cont, cx, cy, cz)
      slab_list = Introspect.slabs(model)
      ffls = Introspect.storeys(slab_list).map { |s| s['ffl_z'] }
      found = Introspect.openings_of(cont, ffls)
      best = nil
      best_d = 1e9
      found.each do |o|
        p = o[:cluster][:primary]
        d = Math.sqrt((p[:cx] - cx)**2 + (p[:cy] - cy)**2 + (o[:cluster][:zc] - cz)**2)
        if d < best_d
          best = o
          best_d = d
        end
      end
      if best.nil? || best_d > 0.5
        raise "no opening found near (#{cx}, #{cy}, #{cz}) in container #{cont[:pid]}. " \
              'Re-run list_openings — ids change when geometry moves.'
      end
      [best, found]
    end

    def self.extent(cl, key0, key1)
      [cl[:loops].map { |l| l[key0] }.min, cl[:loops].map { |l| l[key1] }.max]
    end

    # margin on one side, clamped so the region never reaches a sibling opening
    def self.side_margin(edge, direction, siblings, axis_keys)
      m = BASE_MARGIN
      siblings.each do |s|
        s0, s1 = extent(s, axis_keys[0], axis_keys[1])
        gap = direction.negative? ? edge - s1 : s0 - edge
        next if gap <= 0
        m = [m, [MIN_MARGIN, gap * 0.45].max].min
      end
      m
    end

    # Compute the vertex moves for a resize without applying them. Shared by
    # dry_run and the real path so BUG-20 cannot come back: dry_run reports
    # the same clamped numbers the real edit will produce.
    def self.plan_resize(model, cont, target, siblings, width, height, sill)
      cl = target[:cluster]
      prim = cl[:primary]
      axis = cl[:axis]

      h0, h1 = prim[:h0], prim[:h1]
      z0, z1 = prim[:z0], prim[:z1]
      hc = (h0 + h1) / 2.0
      zmid = (z0 + z1) / 2.0
      ffl = target[:ffl]
      nz0 = sill.nil? ? z0 : ffl + sill.to_f
      nz1 = nz0 + height
      nh0 = hc - width / 2.0
      nh1 = hc + width / 2.0
      dh_low = nh0 - h0; dh_high = nh1 - h1
      dz_low = nz0 - z0; dz_high = nz1 - z1

      rh0, rh1 = extent(cl, :h0, :h1)
      rz0, rz1 = extent(cl, :z0, :z1)
      rn0, rn1 = extent(cl, :n0, :n1)
      box = {
        h: [rh0 - side_margin(rh0, -1, siblings, %i[h0 h1]),
            rh1 + side_margin(rh1, 1, siblings, %i[h0 h1])],
        z: [rz0 - BASE_MARGIN, rz1 + BASE_MARGIN],
        n: [rn0 - NORM_MARGIN, rn1 + NORM_MARGIN]
      }

      shell = Util.cont_bbox(cont)
      sh_lo = axis == 'x' ? shell[:min][0] : shell[:min][1]
      sh_hi = axis == 'x' ? shell[:max][0] : shell[:max][1]
      sz_lo = shell[:min][2]; sz_hi = shell[:max][2]

      inv = cont[:transform].inverse
      moves = []
      clamped = false
      Util.vertices_of(cont[:entity].definition).each do |v|
        wp = v.position.transform(cont[:transform])
        wx = Util.to_m(wp.x); wy = Util.to_m(wp.y); wz = Util.to_m(wp.z)
        hcoord = axis == 'x' ? wx : wy
        ncoord = axis == 'x' ? wy : wx
        next unless hcoord.between?(box[:h][0], box[:h][1])
        next unless wz.between?(box[:z][0], box[:z][1])
        next unless ncoord.between?(box[:n][0], box[:n][1])
        dh = hcoord < hc ? dh_low : dh_high
        dz = wz < zmid ? dz_low : dz_high
        # never move a vertex outside the container's shell — a sill dropped
        # to the shell bottom lands ON it (clean notch) rather than below it
        if hcoord + dh < sh_lo then dh = sh_lo - hcoord; clamped = true end
        if hcoord + dh > sh_hi then dh = sh_hi - hcoord; clamped = true end
        if wz + dz < sz_lo then dz = sz_lo - wz; clamped = true end
        if wz + dz > sz_hi then dz = sz_hi - wz; clamped = true end
        next if dh.abs < 1e-9 && dz.abs < 1e-9
        tp = Geom::Point3d.new(
          wp.x + (axis == 'x' ? Util.to_in(dh) : 0),
          wp.y + (axis == 'y' ? Util.to_in(dh) : 0),
          wp.z + Util.to_in(dz)
        )
        tl = tp.transform(inv)
        moves << [v, tl - v.position]
      end

      # How wide/tall could this opening actually get, keeping its centre?
      # Reported so the agent can offer real numbers instead of dead-ending.
      left_edge = sh_lo
      right_edge = sh_hi
      near_left = near_right = nil
      siblings.each do |s|
        s0, s1 = extent(s, :h0, :h1)
        if s1 <= h0 + 1e-6 && s1 > left_edge
          left_edge = s1; near_left = s
        elsif s0 >= h1 - 1e-6 && s0 < right_edge
          right_edge = s0; near_right = s
        end
      end
      max_w = 2 * [hc - left_edge, right_edge - hc].min
      max_h = sz_hi - nz0
      limited_by = if (hc - left_edge) < (right_edge - hc)
                     near_left ? 'neighbouring_opening' : 'wall_shell'
                   else
                     near_right ? 'neighbouring_opening' : 'wall_shell'
                   end

      { moves: moves, clamped: clamped,
        limits: { 'max_width_here' => Util.r([max_w, 0].max, 3),
                  'max_height_here' => Util.r([max_h, 0].max, 3),
                  'limited_by' => limited_by,
                  'host_span' => [Util.r(sh_lo, 2), Util.r(sh_hi, 2)],
                  'free_span' => [Util.r(left_edge, 2), Util.r(right_edge, 2)] },
        projected: { 'width' => Util.r([nh1 - nh0, sh_hi - sh_lo].min, 3),
                     'height' => Util.r([nz1 - nz0, sz_hi - sz_lo].min, 3),
                     'sill_above_floor' => Util.r([nz0, sz_lo].max - ffl, 3) },
        current: { 'width' => Util.r(h1 - h0, 3), 'height' => Util.r(z1 - z0, 3),
                   'sill_above_floor' => Util.r(z0 - ffl, 3) },
        deltas: { 'h_low' => Util.r(dh_low), 'h_high' => Util.r(dh_high),
                  'z_low' => Util.r(dz_low), 'z_high' => Util.r(dz_high) },
        target_centre: [axis == 'x' ? hc : prim[:cx], axis == 'y' ? hc : prim[:cy],
                        (nz0 + nz1) / 2.0] }
    end

    def self.resize_opening(params)
      model = Sketchup.active_model
      pid, cx, cy, cz = parse_id(params.fetch('id'))
      width  = params.fetch('width').to_f
      height = params.fetch('height').to_f
      sill   = params['sill']
      dry    = params.fetch('dry_run', false)

      # BUG-03 family: validate before touching anything
      raise "width must be > 0 (got #{width})" unless width.positive?
      raise "height must be > 0 (got #{height})" unless height.positive?
      if width > MAX_OPENING_DIM || height > MAX_OPENING_DIM
        raise "width/height must be <= #{MAX_OPENING_DIM}m (got #{width} x #{height})"
      end
      if sill && sill.to_f.negative?
        raise "sill must be >= 0 (got #{sill}); it is measured up from the finished floor"
      end

      cont, unique_report = editable_container(model, pid, params.fetch('auto_unique', true))

      target, all = find_opening(model, cont, cx, cy, cz)
      if target[:kind] == 'ASSEMBLY'
        raise 'this opening is a multi-light ASSEMBLY (a spanning recess around ' \
              'several lights). Resize each light individually, not the assembly.'
      end
      cl = target[:cluster]
      siblings = all.map { |o| o[:cluster] }
                    .select { |c| !c.equal?(cl) && c[:axis] == cl[:axis] && (c[:zc] - cl[:zc]).abs < 2.5 }

      plan = plan_resize(model, cont, target, siblings, width, height, sill)

      base = {
        'opening_id' => params['id'],
        'kind' => target[:kind],
        'current' => plan[:current],
        'requested' => { 'width' => width, 'height' => height,
                         'sill_above_floor' => sill.nil? ? plan[:current]['sill_above_floor'] : sill.to_f },
        'projected' => plan[:projected],
        'clamped' => plan[:clamped],
        'limits' => plan[:limits],
        'vertices' => plan[:moves].length,
        'deltas' => plan[:deltas]
      }
      base['made_unique'] = unique_report if unique_report
      rem = remedies_for(plan, width, height)
      base['remedies'] = rem unless rem.empty?
      # BUG-20: dry_run now reports the clamped projection, not the raw request
      return base.merge('dry_run' => true) if dry

      if plan[:moves].empty?
        raise 'no vertices matched the opening region; geometry may have changed — ' \
              're-run list_openings for fresh ids'
      end

      op_open = false
      begin
        model.start_operation("Archie: resize opening #{width}x#{height}", true)
        op_open = true
        Util.ents_of(cont).transform_by_vectors(
          plan[:moves].map { |m| m[0] }, plan[:moves].map { |m| m[1] }
        )
        # BUG-02: verify while still inside the operation so a bad result can
        # be rolled back instead of being reported as a failure after the fact
        fresh = Util.find_container(model, pid)
        tc = plan[:target_centre]
        verified, achieved, err = verify_resize(model, fresh, tc, width, height)
        unless verified
          model.abort_operation
          op_open = false
          Versioning.bump!
          opts = remedies_for(plan, width, height)
          hint = opts.empty? ? '' : ' OPTIONS: ' +
                 opts.map { |o| "#{o['action']} — #{o['detail']}" }.join(' | ')
          raise "resize failed verification and was ROLLED BACK (model unchanged). " \
                "Requested #{width} x #{height}, achieved #{achieved.inspect}. #{err}" \
                "#{hint} Offer these to the user rather than stopping."
        end
        model.commit_operation
        op_open = false
        Versioning.bump! # never rely on the observer alone (BUG-01)
        base.merge('achieved' => achieved, 'verified' => true,
                   'new_id' => Introspect.opening_id(fresh, { cx: tc[0], cy: tc[1] },
                                                     { zc: tc[2] }))
      rescue StandardError => e
        if op_open
          model.abort_operation
          Versioning.bump!
        end
        raise e
      end
    end

    # Combine adjacent openings into one by cutting away the wall material
    # (mullions) between them.
    #
    # Expressed as "cut the gaps" rather than "delete this geometry": it reuses
    # the verified cut path, and it keeps the schema closed — there is still no
    # tool that deletes arbitrary geometry.
    def self.merge_openings(params)
      model = Sketchup.active_model
      ids = params.fetch('opening_ids')
      raise 'merge_openings needs at least 2 opening_ids' if !ids.is_a?(Array) || ids.length < 2

      pids = ids.map { |i| parse_id(i)[0] }.uniq
      unless pids.length == 1
        raise "all openings must live in the same wall (got container pids #{pids.inspect}). " \
              'Merging across separate walls is not possible.'
      end
      cont, unique_report = editable_container(model, pids.first,
                                               params.fetch('auto_unique', true))

      slab_list = Introspect.slabs(model)
      ffls = Introspect.storeys(slab_list).map { |s| s['ffl_z'] }
      present = Introspect.openings_of(cont, ffls)

      # match by world position, not pid: make_unique re-issues pids but does
      # not move anything
      targets = ids.map do |id|
        _, cx, cy, cz = parse_id(id)
        best = present.min_by do |o|
          p = o[:cluster][:primary]
          (p[:cx] - cx)**2 + (p[:cy] - cy)**2 + (o[:cluster][:zc] - cz)**2
        end
        d = if best
              p = best[:cluster][:primary]
              Math.sqrt((p[:cx] - cx)**2 + (p[:cy] - cy)**2 + (best[:cluster][:zc] - cz)**2)
            else
              1e9
            end
        raise "opening #{id} not found in this wall — re-run list_openings" if d > 0.5
        best
      end

      axis = targets.first[:cluster][:axis]
      unless targets.all? { |t| t[:cluster][:axis] == axis }
        raise 'these openings are not on the same wall plane, so they cannot be merged'
      end
      h_axis = axis == 'x' ? 0 : 1
      n_axis = 1 - h_axis

      sorted = targets.sort_by { |t| t[:cluster][:primary][:h0] }
      z0s = sorted.map { |t| t[:cluster][:primary][:z0] }
      z1s = sorted.map { |t| t[:cluster][:primary][:z1] }
      aligned = (z0s.max - z0s.min) < 0.03 && (z1s.max - z1s.min) < 0.03
      z0 = aligned ? z0s.min : z0s.max
      z1 = aligned ? z1s.max : z1s.min
      if z1 - z0 < 0.05
        raise 'these openings barely overlap vertically; merging them would leave a sliver. ' \
              'Resize them to a common height first.'
      end

      gaps = []
      sorted.each_cons(2) do |a, b|
        g0 = a[:cluster][:primary][:h1]
        g1 = b[:cluster][:primary][:h0]
        gaps << [g0, g1] if g1 - g0 > 0.005
      end
      if gaps.empty?
        raise 'these openings are already contiguous — nothing to remove between them'
      end

      span0 = sorted.first[:cluster][:primary][:h0]
      span1 = sorted.last[:cluster][:primary][:h1]

      # Derive the wall plane from the openings themselves rather than the
      # container bbox — required at model root, where the "container" is the
      # whole building and loose faces have no wall of their own.
      plane_n = targets.map { |t| t[:cluster][:loops].map { |l| l[:n0] }.min }.min
      far_n = targets.map { |t| t[:cluster][:loops].map { |l| l[:n1] }.max }.max
      wall_thickness = far_n - plane_n
      if wall_thickness < 0.01
        raise 'these openings sit in a single-plane wall (zero thickness), so there is ' \
              'no material to cut through. Merging would mean deleting the faces between ' \
              'them, which no tool does yet — see docs.'
      end

      op = false
      begin
        model.start_operation("Archie: merge #{targets.length} openings", true)
        op = true
        gaps.each do |g0, g1|
          unless Create.cut_rect(cont, h_axis, n_axis, g0, g1, z0, z1,
                                 plane_n, wall_thickness)
            model.abort_operation
            op = false
            Versioning.bump!
            raise 'merge failed and was ROLLED BACK (wall unchanged): could not cut the ' \
                  "strip between #{Util.r(g0, 2)} and #{Util.r(g1, 2)}."
          end
        end

        fresh = Util.find_container(model, cont[:pid]) || cont
        after = Introspect.openings_of(fresh, ffls)
        merged = after.find do |o|
          p = o[:cluster][:primary]
          p[:h0] <= span0 + 0.03 && p[:h1] >= span1 - 0.03 &&
            (p[:z0] - z0).abs < 0.05 && !o[:cluster][:assembly]
        end
        unless merged
          model.abort_operation
          op = false
          Versioning.bump!
          raise 'merge failed verification and was ROLLED BACK (wall unchanged): the ' \
                'openings did not join into one. The wall may not be a clean solid.'
        end
        model.commit_operation
        op = false
        Versioning.bump!
        mp = merged[:cluster][:primary]
        out = {
          'merged_count' => targets.length,
          'mullions_removed' => gaps.length,
          'mullion_widths' => gaps.map { |g0, g1| Util.r(g1 - g0, 3) },
          'opening_id' => merged[:id], 'kind' => merged[:kind],
          'width' => Util.r(mp[:w], 3), 'height' => Util.r(mp[:h], 3),
          'sill_above_floor' => Util.r(mp[:z0] - merged[:ffl], 3),
          'verified' => true
        }
        out['made_unique'] = unique_report if unique_report
        out
      rescue StandardError => e
        if op
          model.abort_operation
          Versioning.bump!
        end
        raise e
      end
    end

    # Concrete, numbered options for a request the wall cannot satisfy.
    # An architect expects "here is what we would have to change" — not "no".
    def self.remedies_for(plan, width, height)
      lim = plan[:limits]
      out = []
      if width > lim['max_width_here'] + 0.005
        short = Util.r(width - lim['max_width_here'], 3)
        out << { 'action' => 'accept_max_width',
                 'width' => lim['max_width_here'],
                 'detail' => "keep everything else as-is and settle for " \
                             "#{lim['max_width_here']}m instead of #{width}m" }
        if lim['limited_by'] == 'wall_shell'
          out << { 'action' => 'extend_host_wall',
                   'extra_needed_m' => short,
                   'detail' => "the host wall spans #{lim['host_span'][0]}–#{lim['host_span'][1]}m; " \
                               "it needs #{short}m more length for the opening to fit. " \
                               'Extending a wall moves whatever it meets at that end.' }
        else
          out << { 'action' => 'move_neighbouring_opening',
                   'shift_needed_m' => short,
                   'detail' => "a neighbouring opening limits the free span to " \
                               "#{lim['free_span'][0]}–#{lim['free_span'][1]}m; moving it " \
                               "#{short}m away would make room" }
        end
        out << { 'action' => 'recentre_opening',
                 'detail' => 'the limit above assumes the opening keeps its current centre; ' \
                             'sliding it along the wall may free up more room on one side' }
      end
      if height > lim['max_height_here'] + 0.005
        out << { 'action' => 'accept_max_height', 'height' => lim['max_height_here'],
                 'detail' => "the wall is only #{lim['max_height_here']}m tall above this sill; " \
                             'lowering the sill or raising the wall would be needed for ' \
                             "#{height}m" }
      end
      out
    end

    def self.verify_resize(model, cont, target_centre, width, height)
      slab_list = Introspect.slabs(model)
      ffls = Introspect.storeys(slab_list).map { |s| s['ffl_z'] }
      found = Introspect.openings_of(cont, ffls)
      best = nil; best_d = 1e9
      found.each do |o|
        p = o[:cluster][:primary]
        d = Math.sqrt((p[:cx] - target_centre[0])**2 + (p[:cy] - target_centre[1])**2 +
                      (o[:cluster][:zc] - target_centre[2])**2)
        if d < best_d then best = o; best_d = d end
      end
      return [false, nil, 'the opening could not be found after the edit'] if best.nil? || best_d > 0.6
      p = best[:cluster][:primary]
      achieved = { 'width' => Util.r(p[:w], 3), 'height' => Util.r(p[:h], 3),
                   'sill_above_floor' => Util.r(p[:z0] - best[:ffl], 3) }
      ok = (p[:w] - width).abs <= TOL && (p[:h] - height).abs <= TOL
      msg = ok ? nil : 'the wall could not accommodate the requested size ' \
                       '(clamped by the wall shell or a neighbouring opening)'
      [ok, achieved, msg]
    end

    def self.set_slab_thickness(params)
      model = Sketchup.active_model
      pid = params.fetch('pid').to_i
      thickness = params.fetch('thickness').to_f
      datum = params.fetch('datum', 'top')
      tol = params.fetch('tolerance', 0.02).to_f
      raise "datum must be 'top' or 'bottom' (got #{datum.inspect})" unless %w[top bottom].include?(datum)

      # BUG-03: these three inputs each corrupted a real model before this guard
      #   -0.5 inverted the slab; 0 created zero-volume geometry and reported
      #   verified:true; 500 teleported it to z=-499.5
      unless thickness.positive?
        raise "thickness must be > 0 (got #{thickness}). A zero or negative thickness " \
              'would create degenerate or inverted geometry.'
      end
      if thickness > MAX_SLAB_THICKNESS
        raise "thickness must be <= #{MAX_SLAB_THICKNESS}m (got #{thickness}). " \
              'Pass a value in METRES.'
      end

      cont = Util.find_container(model, pid)
      raise "container pid #{pid} not found" unless cont
      guard_editable(cont)

      bb = Util.world_bbox(cont[:entity], cont[:transform])
      z_bot = bb[:min][2]; z_top = bb[:max][2]
      current = z_top - z_bot
      if current < 0.001
        raise "slab #{pid} has zero thickness already (z=#{Util.r(z_bot)}); it is " \
              'degenerate geometry and cannot be resized reliably. Repair it in SketchUp.'
      end
      # The selection tolerance must stay well under the slab's own thickness,
      # or a thin slab (finish layers are often 10-20mm) has BOTH faces inside
      # the tolerance: every vertex moves together and the thickness never
      # changes, which then reads as a mysterious verification failure.
      tol = [tol, current * 0.4].min
      if tol < 1e-4
        raise "slab #{pid} is only #{Util.r(current, 4)}m thick — too thin to edit reliably " \
              'by plane selection. Rebuild it, or use transform_component to scale it.'
      end
      plane = datum == 'top' ? z_bot : z_top
      dz = datum == 'top' ? (z_top - thickness) - z_bot : (z_bot + thickness) - z_top

      # BUG-07: walk nested geometry too — a slab detected by bbox at this
      # level often keeps its faces one level deeper
      groups = Util.deep_vertex_groups(cont[:entity], cont[:transform])
      shared_nested = groups.select { |g| g[:shared] }
      unless shared_nested.empty?
        raise "slab #{pid} contains shared/instanced nested geometry; editing it would " \
              'change every occurrence. Make it unique in SketchUp first.'
      end

      picked = groups.map do |g|
        sel = g[:verts].select do |v|
          (Util.to_m(v.position.transform(g[:transform]).z) - plane).abs < tol
        end
        next nil if sel.empty?
        inv = g[:transform].inverse
        vecs = sel.map do |v|
          wp = v.position.transform(g[:transform])
          Geom::Point3d.new(wp.x, wp.y, wp.z + Util.to_in(dz)).transform(inv) - v.position
        end
        { entities: g[:entities], verts: sel, vecs: vecs }
      end.compact

      if picked.empty?
        raise "no vertices found at z=#{Util.r(plane)} (tolerance #{tol}m) in slab #{pid} " \
              "or its nested geometry. The slab's bounding box may come from a child " \
              'that does not reach that plane; try the other datum.'
      end

      op_open = false
      begin
        model.start_operation("Archie: slab thickness #{thickness}m", true)
        op_open = true
        picked.each { |g| g[:entities].transform_by_vectors(g[:verts], g[:vecs]) }
        # live bbox: definition.bounds is stale until commit (see Util)
        nb = Util.world_bbox_live(cont[:entity], cont[:transform])
        achieved = Util.r(nb[:max][2] - nb[:min][2])
        unless (achieved - thickness).abs <= 0.01
          model.abort_operation
          op_open = false
          Versioning.bump!
          raise "slab thickness change failed verification and was ROLLED BACK " \
                "(model unchanged). Requested #{thickness}m, achieved #{achieved}m."
        end
        model.commit_operation
        op_open = false
        Versioning.bump!
        {
          'pid' => pid, 'datum' => datum,
          'moved_vertices' => picked.sum { |g| g[:verts].length },
          'nested_groups_touched' => picked.length,
          'before' => { 'z_bottom' => z_bot, 'z_top' => z_top, 'thickness' => Util.r(current) },
          'after' => { 'z_bottom' => nb[:min][2], 'z_top' => nb[:max][2], 'thickness' => achieved },
          'verified' => true
        }
      rescue StandardError => e
        if op_open
          model.abort_operation
          Versioning.bump!
        end
        raise e
      end
    end
  end
end
