# Read-only tools: get_model_info, list_openings, get_selection.
#
# The classification rule (sill/head) was validated against a real client
# model where doors and windows are literally identical geometry (holes in
# wall solids): DOOR <=> sill<=0.10m above FFL AND head>=1.95m; WINDOW <=>
# sill>0.15m; anything between is reported AMBIGUOUS rather than guessed.
require_relative 'util'

module Archie
  module Introspect
    SLAB_MIN_AREA  = 15.0  # m^2
    SLAB_MAX_THICK = 0.8   # m
    SLAB_MIN_THICK = 0.02  # m

    # BUG-05: clustering MUST NOT depend on the caller's display filter.
    # list_openings used to cluster at min 0.5 while resize_opening's
    # find_cluster used 0.15, so the two tools disagreed about whether the
    # same hole was a WINDOW or an ASSEMBLY. Everything now clusters at this
    # one canonical floor and filters only for presentation.
    CANON_MIN = 0.05
    CLUSTER_TOL = 0.15

    # A container smaller than this in every direction cannot be a wall, so
    # holes found inside it are furniture detail, not architecture (BUG-14:
    # a 2cm chandelier part was being reported as a WINDOW).
    HOST_MIN_SPAN = 1.0

    def self.slabs(model, conts = nil)
      conts ||= Util.containers(model)
      out = []
      conts.each do |c|
        next if c[:root] # the root pseudo-container is the whole model, not a slab
        bb = Util.world_bbox(c[:entity], c[:transform])
        dx, dy, dz = bb[:size]
        next unless dz < SLAB_MAX_THICK
        next unless dx > 2.0 && dy > 2.0 && (dx * dy) > SLAB_MIN_AREA

        anomalies = []
        # BUG-04: a slab flattened to zero thickness used to vanish from the
        # inventory entirely, leaving orphaned geometry the architect could
        # neither find nor repair. Report it, flagged, instead of hiding it.
        anomalies << 'zero_thickness' if dz < SLAB_MIN_THICK
        anomalies << 'below_ground' if bb[:max][2] < -50.0

        # BUG-07: can set_slab_thickness actually reach this slab's vertices?
        direct = Util.vertices_of(c[:entity].definition).length
        deep = Util.deep_vertex_groups(c[:entity], c[:transform])
        reachable = deep.sum { |g| g[:verts].length }
        editable = !c[:shared] && reachable.positive?
        reason = if c[:shared] then 'shared_geometry'
                 elsif reachable.zero? then 'no_vertices_found'
                 end

        out << {
          'pid' => c[:pid], 'path' => c[:path],
          'z_bottom' => bb[:min][2], 'z_top' => bb[:max][2],
          'thickness' => Util.r(dz), 'footprint' => [dx, dy],
          'area_m2' => Util.r(dx * dy, 1),
          'shared' => c[:shared],
          'editable' => editable,
          'nested_geometry' => direct.zero? && reachable.positive?,
          'anomalies' => anomalies
        }.tap { |h| h['not_editable_reason'] = reason if reason }
      end
      out.sort_by { |s| s['z_bottom'] }
    end

    # Candidate finished-floor levels = EVERY plausible slab top, plus the
    # ground plane 0.0. ffl_for() picks the highest candidate at-or-below an
    # opening, so extra candidates are harmless — whereas area-dominance
    # filtering proved actively wrong on a real model, where a 606 m2 terrain
    # slab and 365 m2 material sample boards out-dominated the actual house
    # slabs and every door misclassified as WINDOW.
    def self.storeys(slab_list)
      tops = slab_list.reject { |s| s['anomalies'].include?('zero_thickness') }
                      .map { |s| s['z_top'] } + [0.0]
      ffls = []
      tops.sort.each { |z| ffls << z if ffls.empty? || (z - ffls.last).abs > 0.05 }
      ffls.each_with_index.map { |z, i| { 'name' => "N#{i}", 'ffl_z' => Util.r(z) } }
    end

    def self.get_model_info(params)
      model = Sketchup.active_model
      conts = Util.containers(model)
      slab_list = slabs(model, conts)
      info = {
        'path' => model.path.to_s, 'title' => model.title.to_s,
        'modified' => model.modified?,
        'units' => model.options['UnitsOptions']['LengthUnit'],
        'containers' => conts.length,
        'definitions' => model.definitions.count,
        'layers' => model.layers.count,
        'slabs' => slab_list,
        'storeys' => storeys(slab_list)
      }
      anomalous = slab_list.reject { |s| s['anomalies'].empty? }
      info['slab_anomalies'] = anomalous.length unless anomalous.empty?
      if params.fetch('include_top_level', true)
        info['top_level'] = model.entities
          .select { |e| e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }
          .first(60).map do |e|
            bb = Util.world_bbox(e, e.transformation)
            { 'pid' => e.persistent_id,
              'kind' => e.is_a?(Sketchup::Group) ? 'group' : 'component',
              'name' => e.name.to_s, 'defn' => e.definition.name,
              'min' => bb[:min], 'size' => bb[:size],
              'entities' => e.definition.entities.count }
          end
      end
      info
    end

    # --- openings ---------------------------------------------------------
    # An opening = cluster of vertical inner loops. One physical opening shows
    # up as several concentric loops (rough opening + daylight opening, on
    # both wall faces); concentric loops share an in-plane centre, while
    # adjacent lights of a multi-leaf assembly differ by >= a leaf width, so
    # clustering on |in-plane centre delta| < 0.15m merges reveals without
    # merging leaves. Validated against CASA_CUMBRES (test/CASA_CUMBRES_KB.md).

    def self.loops_of_container(cont)
      loops = []
      Util.ents_of(cont).grep(Sketchup::Face).each do |f|
        next if f.loops.length < 2
        n = f.normal.transform(cont[:transform])
        next if n.z.abs > 0.7 # horizontal face -> slab hole, not a wall opening
        axis = nil
        axis = 'y' if n.x.abs > 0.7 # wall faces east/west -> in-plane horizontal is Y
        axis = 'x' if n.y.abs > 0.7
        next unless axis
        f.loops.each do |lp|
          next if lp.outer?
          xs = []; ys = []; zs = []
          lp.vertices.each do |v|
            p = v.position.transform(cont[:transform])
            xs << Util.to_m(p.x); ys << Util.to_m(p.y); zs << Util.to_m(p.z)
          end
          w = axis == 'x' ? (xs.max - xs.min) : (ys.max - ys.min)
          h = zs.max - zs.min
          next if w < CANON_MIN || h < CANON_MIN
          loops << {
            axis: axis, w: w, h: h,
            h0: axis == 'x' ? xs.min : ys.min, h1: axis == 'x' ? xs.max : ys.max,
            z0: zs.min, z1: zs.max,
            n0: axis == 'x' ? ys.min : xs.min, n1: axis == 'x' ? ys.max : xs.max,
            cx: (xs.min + xs.max) / 2.0, cy: (ys.min + ys.max) / 2.0,
            cz: (zs.min + zs.max) / 2.0, nv: lp.vertices.length
          }
        end
      end
      loops
    end

    def self.cluster_loops(loops)
      clusters = []
      loops.each do |lp|
        hc = (lp[:h0] + lp[:h1]) / 2.0
        zc = (lp[:z0] + lp[:z1]) / 2.0
        home = clusters.find do |cl|
          cl[:axis] == lp[:axis] &&
            (cl[:hc] - hc).abs < CLUSTER_TOL && (cl[:zc] - zc).abs < CLUSTER_TOL
        end
        if home
          home[:loops] << lp
        else
          clusters << { axis: lp[:axis], hc: hc, zc: zc, loops: [lp] }
        end
      end
      # primary = largest loop; recompute cluster centre from it
      clusters.each do |cl|
        prim = cl[:loops].max_by { |l| l[:w] * l[:h] }
        cl[:primary] = prim
        cl[:hc] = (prim[:h0] + prim[:h1]) / 2.0
        cl[:zc] = (prim[:z0] + prim[:z1]) / 2.0
      end
      # assembly detection: a cluster whose in-plane extent contains the
      # centres of >=2 sibling clusters is a spanning recess / rough opening
      # around a multi-leaf assembly, not an individually-editable opening.
      clusters.each do |cl|
        prim = cl[:primary]
        inside = clusters.count do |o|
          next false if o.equal?(cl)
          o[:axis] == cl[:axis] && o[:hc] > prim[:h0] && o[:hc] < prim[:h1] &&
            (o[:zc] - cl[:zc]).abs < 1.5
        end
        cl[:assembly] = inside >= 2
      end
      clusters
    end

    def self.classify(sill, head)
      return 'DOOR'   if sill <= 0.10 && head >= 1.95
      return 'WINDOW' if sill > 0.15
      'AMBIGUOUS'
    end

    def self.ffl_for(sill_z, ffls)
      below = ffls.select { |z| z <= sill_z + 0.35 }
      below.empty? ? ffls.min : below.max
    end

    def self.opening_id(cont, prim, cl)
      format('%d:%.2f,%.2f,%.2f', cont[:pid], prim[:cx], prim[:cy], cl[:zc])
    end

    # Every opening in a container, canonical clustering, no display filter.
    # Shared by list_openings and Edit.find_cluster so the two can never
    # disagree about kind (BUG-05).
    def self.openings_of(cont, ffls)
      host = Util.cont_bbox(cont)
      host_span = host[:size].max
      # the root pseudo-container is the whole model, so the furniture-size
      # heuristic cannot apply to it
      likely_furniture = !cont[:root] && host_span < HOST_MIN_SPAN
      cluster_loops(loops_of_container(cont)).map do |cl|
        prim = cl[:primary]
        ffl = ffl_for(prim[:z0], ffls)
        sill = prim[:z0] - ffl
        head = prim[:z1] - ffl
        kind = cl[:assembly] ? 'ASSEMBLY' : classify(sill, head)
        depth = cl[:loops].map { |l| l[:n1] }.max - cl[:loops].map { |l| l[:n0] }.min
        anomalies = []
        anomalies << 'negative_sill' if sill < -0.02      # BUG-15
        anomalies << 'thin_host' if depth < 0.03
        { cluster: cl, kind: kind, sill: sill, head: head, ffl: ffl,
          depth: depth, likely_furniture: likely_furniture, anomalies: anomalies,
          id: opening_id(cont, prim, cl), cont: cont }
      end
    end

    def self.list_openings(params)
      model = Sketchup.active_model
      min_w = params.fetch('min_width', 0.5).to_f
      min_h = params.fetch('min_height', 0.5).to_f
      raise 'min_width must be >= 0' if min_w.negative?    # BUG-13
      raise 'min_height must be >= 0' if min_h.negative?
      want_kind = params['kind']
      if want_kind && !%w[DOOR WINDOW AMBIGUOUS ASSEMBLY].include?(want_kind)
        raise "kind must be one of DOOR, WINDOW, AMBIGUOUS, ASSEMBLY (got #{want_kind.inspect})"
      end
      include_furniture = params.fetch('include_furniture', false)
      summary_only = params.fetch('summary', false)
      limit = params.fetch('limit', 60).to_i
      offset = params.fetch('offset', 0).to_i

      conts = Util.containers(model)
      slab_list = slabs(model, conts)
      ffls = storeys(slab_list).map { |s| s['ffl_z'] }

      want_pid = params['container_pid']
      if want_pid && want_pid.to_i != 0
        targets = conts.select { |c| c[:pid] == want_pid.to_i }
        # BUG-12: an unknown pid used to return [] silently, which reads as
        # "this wall has no openings" instead of "you passed a bad id".
        raise "container pid #{want_pid} not found in this model" if targets.empty?
      else
        targets = conts
      end

      all = []
      targets.each { |cont| all.concat(openings_of(cont, ffls)) }

      furniture_excluded = 0
      rows = all.reject do |o|
        drop = !include_furniture && o[:likely_furniture]
        furniture_excluded += 1 if drop
        drop
      end
      rows = rows.select { |o| o[:cluster][:primary][:w] >= min_w && o[:cluster][:primary][:h] >= min_h }
      rows = rows.select { |o| o[:kind] == want_kind } if want_kind
      rows = rows.sort_by { |o| [o[:cluster][:primary][:z0], o[:cluster][:primary][:cx], o[:cluster][:primary][:cy]] }

      counts = Hash.new(0)
      rows.each { |o| counts[o[:kind]] += 1 }
      by_container = Hash.new(0)
      rows.each { |o| by_container[o[:cont][:path]] += 1 }

      result = {
        'total' => rows.length,
        'by_kind' => counts,
        'furniture_excluded' => furniture_excluded,
        'filters' => { 'min_width' => min_w, 'min_height' => min_h,
                       'kind' => want_kind, 'include_furniture' => include_furniture }
      }
      if summary_only
        result['by_container'] = by_container.sort_by { |_, v| -v }.first(25).to_h
        return result
      end

      page = rows[offset, limit] || []
      result['offset'] = offset
      result['returned'] = page.length
      result['openings'] = page.map do |o|
        prim = o[:cluster][:primary]
        h = {
          'id' => o[:id], 'kind' => o[:kind],
          'width' => Util.r(prim[:w], 2), 'height' => Util.r(prim[:h], 2),
          'sill_above_floor' => Util.r(o[:sill], 2),
          'head_above_floor' => Util.r(o[:head], 2),
          'ffl_z' => Util.r(o[:ffl], 2),
          'host_depth' => Util.r(o[:depth], 3),
          'container_pid' => o[:cont][:pid], 'container_path' => o[:cont][:path],
          'shared' => o[:cont][:shared]
        }
        h['anomalies'] = o[:anomalies] unless o[:anomalies].empty?
        h['likely_furniture'] = true if o[:likely_furniture]
        h
      end
      result
    end

    # World bbox of any entity (faces and edges included, not just containers).
    def self.entity_world_bbox(e, wtr)
      pts = []
      if e.respond_to?(:vertices)
        e.vertices.each { |v| pts << v.position.transform(wtr) }
      elsif e.respond_to?(:definition)
        bb = e.definition.bounds
        (0..7).each { |i| pts << bb.corner(i).transform(wtr * e.transformation) }
      end
      return nil if pts.empty?
      xs = pts.map(&:x); ys = pts.map(&:y); zs = pts.map(&:z)
      { min: [Util.to_m(xs.min), Util.to_m(ys.min), Util.to_m(zs.min)].map { |v| Util.r(v) },
        max: [Util.to_m(xs.max), Util.to_m(ys.max), Util.to_m(zs.max)].map { |v| Util.r(v) },
        size: [Util.to_m(xs.max - xs.min), Util.to_m(ys.max - ys.min),
               Util.to_m(zs.max - zs.min)].map { |v| Util.r(v) } }
    end

    # Find ANY entity by pid — faces and edges included, at root or nested.
    # Returns {entity:, transform:(world of its owner), owner:} or nil.
    def self.find_any_entity(model, pid, conts = nil)
      model.entities.each do |e|
        if e.respond_to?(:persistent_id) && e.persistent_id == pid
          return { entity: e, transform: Geom::Transformation.new, owner: nil }
        end
      end
      (conts || Util.containers(model)).each do |c|
        Util.ents_of(c).each do |e|
          if e.respond_to?(:persistent_id) && e.persistent_id == pid
            return { entity: e, transform: c[:transform], owner: c }
          end
        end
      end
      nil
    end

    # Which container owns this entity, and with what world transform?
    # Loose entities drawn at the model root have no owning container.
    def self.owner_of(model, entity, conts = nil)
      conts ||= Util.containers(model)
      conts.find { |c| Util.ents_of(c).include?(entity) }
    end

    # get_selection is the bridge between "this thing I clicked" and every
    # editing tool. Selecting a window in SketchUp gives you loose Faces, and
    # the edit tools take container pids and opening ids — so without this
    # resolution step, "resize the window I selected" can never work.
    def self.get_selection(params)
      model = Sketchup.active_model
      sel = model.selection
      conts = Util.containers(model)
      slab_list = slabs(model, conts)
      ffls = storeys(slab_list).map { |s| s['ffl_z'] }
      want_openings = params.fetch('resolve_openings', true)

      items = []
      union = nil
      sel.to_a.first(40).each do |e|
        owner = (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) ? nil : owner_of(model, e, conts)
        wtr = owner ? owner[:transform] : Geom::Transformation.new
        bb = entity_world_bbox(e, wtr)
        h = { 'type' => e.class.name.split('::').last }
        h['pid'] = e.persistent_id if e.respond_to?(:persistent_id)
        h['name'] = e.name if e.respond_to?(:name) && !e.name.to_s.empty?
        if e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          c = conts.find { |x| x[:pid] == e.persistent_id }
          h['container_pid'] = e.persistent_id
          h['container_path'] = c ? c[:path] : nil
          h['shared'] = c ? c[:shared] : nil
          h['defn'] = e.definition.name
        elsif owner
          h['container_pid'] = owner[:pid]
          h['container_path'] = owner[:path]
          h['shared'] = owner[:shared]
        else
          h['container_pid'] = nil
          h['note'] = 'loose geometry at model root — not inside any group or component'
        end
        if bb
          h['min'] = bb[:min]; h['size'] = bb[:size]
          union = union ? [[union[0], bb[:min]].transpose.map(&:min),
                           [union[1], bb[:max]].transpose.map(&:max)]
                        : [bb[:min], bb[:max]]
        end
        items << h
      end

      out = { 'count' => sel.count, 'items' => items }
      return out unless want_openings && union

      # Which openings sit in or next to what the user picked? This is what
      # turns a click into something resize_opening / merge_openings can take.
      pad = 0.6
      near = []
      conts.each do |c|
        cb = Util.cont_bbox(c)
        next if cb[:max][0] < union[0][0] - pad || cb[:min][0] > union[1][0] + pad
        next if cb[:max][1] < union[0][1] - pad || cb[:min][1] > union[1][1] + pad
        next if cb[:max][2] < union[0][2] - pad || cb[:min][2] > union[1][2] + pad
        openings_of(c, ffls).each do |o|
          p = o[:cluster][:primary]
          next if p[:w] < 0.15 || p[:h] < 0.15
          cx = p[:cx]; cy = p[:cy]; cz = o[:cluster][:zc]
          next if cx < union[0][0] - pad || cx > union[1][0] + pad
          next if cy < union[0][1] - pad || cy > union[1][1] + pad
          next if cz < union[0][2] - pad || cz > union[1][2] + pad
          near << { 'id' => o[:id], 'kind' => o[:kind],
                    'width' => Util.r(p[:w], 2), 'height' => Util.r(p[:h], 2),
                    'sill_above_floor' => Util.r(p[:z0] - o[:ffl], 2),
                    'container_pid' => o[:cont][:pid], 'shared' => o[:cont][:shared],
                    'centre' => [Util.r(cx, 2), Util.r(cy, 2), Util.r(cz, 2)] }
        end
      end
      near.sort_by! { |n| [n['centre'][0], n['centre'][1], n['centre'][2]] }
      out['selection_bounds'] = { 'min' => union[0], 'max' => union[1] }
      out['nearby_openings'] = near.first(20)
      out['hint'] = if near.empty?
                      'no openings near this selection'
                    else
                      "#{near.length} opening(s) next to the selection — these ids work " \
                      'with resize_opening and merge_openings'
                    end
      out
    end

    # --- camera / selection helpers (DESIGN-03) ---------------------------
    # Finding one window took a non-expert user six orbit-and-click attempts;
    # groups are unnamed so the Outliner search is useless. Pointing the
    # camera at the thing turns "guess and verify" into "I'll show you".

    def self.locate(params)
      model = Sketchup.active_model
      pid = params['pid']
      opening_id = params['opening_id']
      select = params.fetch('select', true)
      zoom = params.fetch('zoom', true)
      view = model.active_view

      if opening_id && !opening_id.to_s.empty?
        cpid, centre = opening_id.to_s.split(':', 2)
        raise "bad opening_id #{opening_id.inspect} (want 'pid:x,y,z')" unless centre
        cx, cy, cz = centre.split(',').map(&:to_f)
        cont = Util.find_container(model, cpid.to_i)
        raise "container pid #{cpid} not found" unless cont
        entity = cont[:entity]

        # Look at the opening square-on from OUTSIDE the wall. The wall's
        # normal axis is whichever horizontal axis the opening does not run
        # along; "outside" is the side away from the container's centre.
        slab_list = slabs(model)
        ffls = storeys(slab_list).map { |s| s['ffl_z'] }
        near = openings_of(cont, ffls).min_by do |o|
          p = o[:cluster][:primary]
          (p[:cx] - cx)**2 + (p[:cy] - cy)**2 + (o[:cluster][:zc] - cz)**2
        end
        axis = near ? near[:cluster][:axis] : 'x'
        size = near ? [near[:cluster][:primary][:w], near[:cluster][:primary][:h]].max : 1.5
        host = Util.world_bbox(entity, cont[:transform])
        host_centre = [(host[:min][0] + host[:max][0]) / 2.0,
                       (host[:min][1] + host[:max][1]) / 2.0]
        dist = [3.0, size * 2.4].max
        eye = [cx, cy, cz]
        if axis == 'x' # opening runs along X, so the wall faces +/- Y
          eye[1] += cy >= host_centre[1] ? dist : -dist
        else           # runs along Y, wall faces +/- X
          eye[0] += cx >= host_centre[0] ? dist : -dist
        end
        eye[2] += size * 0.15
        view.camera.set(
          Geom::Point3d.new(Util.to_in(eye[0]), Util.to_in(eye[1]), Util.to_in(eye[2])),
          Geom::Point3d.new(Util.to_in(cx), Util.to_in(cy), Util.to_in(cz)),
          Geom::Vector3d.new(0, 0, 1)
        ) if zoom
        centre_m = [cx, cy, cz]
        label = "opening #{opening_id} (#{near ? near[:kind] : '?'})"
      elsif pid && pid.to_i != 0
        cont = Util.find_container(model, pid.to_i)
        unless cont
          # A pid may name a Face or Edge, not a container — that is what a
          # user's SketchUp selection actually consists of, so accept it.
          loose = find_any_entity(model, pid.to_i)
          raise "pid #{pid} not found in this model" unless loose
          entity = loose[:entity]
          bb = entity_world_bbox(entity, loose[:transform])
          raise "pid #{pid} has no geometry to look at" unless bb
          centre_m = [(bb[:min][0] + bb[:max][0]) / 2.0,
                      (bb[:min][1] + bb[:max][1]) / 2.0,
                      (bb[:min][2] + bb[:max][2]) / 2.0]
          view.zoom([entity]) if zoom
          if select
            model.selection.clear
            model.selection.add(entity)
          end
          view.refresh
          return { 'located' => "#{entity.class.name.split('::').last} pid #{pid}" \
                                "#{loose[:owner] ? " inside #{loose[:owner][:path]}" : ' (loose at model root)'}",
                   'centre' => centre_m.map { |v| Util.r(v) },
                   'container_pid' => loose[:owner] ? loose[:owner][:pid] : nil,
                   'selected' => select, 'zoomed' => zoom,
                   'note' => 'this is raw geometry, not a container — use get_selection ' \
                             'to find the opening ids near it' }
        end
        entity = cont[:entity]
        bb = Util.world_bbox(entity, cont[:transform])
        centre_m = [(bb[:min][0] + bb[:max][0]) / 2.0,
                    (bb[:min][1] + bb[:max][1]) / 2.0,
                    (bb[:min][2] + bb[:max][2]) / 2.0]
        # View#zoom takes entities or a Selection — never a BoundingBox
        view.zoom([entity]) if zoom
        label = "#{cont[:path]} (pid #{cont[:pid]})"
      else
        raise 'pass either pid or opening_id'
      end

      if select && entity
        model.selection.clear
        model.selection.add(entity)
      end
      view.refresh

      { 'located' => label,
        'centre' => centre_m.map { |v| Util.r(v) },
        'selected' => select && !entity.nil?,
        'zoomed' => zoom,
        'note' => 'camera moved in SketchUp — ask the user to confirm this is the ' \
                  'element they meant before editing it' }
    end
  end
end
