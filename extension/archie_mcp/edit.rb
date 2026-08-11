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
            'occurrence in the model. Make the chain unique in SketchUp first.'
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

      shell = Util.world_bbox(cont[:entity], cont[:transform])
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

      { moves: moves, clamped: clamped,
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

      cont = Util.find_container(model, pid)
      raise "container pid #{pid} not found" unless cont
      guard_editable(cont)

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
        'vertices' => plan[:moves].length,
        'deltas' => plan[:deltas]
      }
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
        cont[:entity].definition.entities.transform_by_vectors(
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
          raise "resize failed verification and was ROLLED BACK (model unchanged). " \
                "Requested #{width} x #{height}, achieved #{achieved.inspect}. #{err}"
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
        nb = Util.world_bbox(Util.find_container(model, pid)[:entity], cont[:transform])
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
