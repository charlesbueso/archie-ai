# Rebuild the proposal copy from the pristine original and apply Omar's spec.
#
# Deterministic and idempotent: it deletes any previous copy first, so it can be
# re-run after editing logs/edit_plan.json without depending on SketchUp's undo
# stack (Sketchup.send_action("editUndo:") is queued and proved unreliable here).
#
# Invoke with:  eval(File.read("B:/repos/archie-ai/tools/apply_spec.rb"))
require 'json'

model = Sketchup.active_model
model.start_operation('Copia propuesta Omar (rebuild + spec)', true)
begin
  plan = JSON.parse(File.read("B:/repos/archie-ai/logs/edit_plan.json"))
  OFF = 20.0 unless defined?(OFF)
  EXCLUDE = ["Group#1", "skp2BBD", "T4Ever_V8_087_C"] unless defined?(EXCLUDE)
  NAME = "CASA_CUMBRES_PROPUESTA_OMAR" unless defined?(NAME)

  model.entities.grep(Sketchup::Group).select { |g| g.name == NAME }
       .each { |g| model.entities.erase_entities(g) }

  srcs = model.entities.select { |e|
    (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) &&
      e.bounds.min.x.to_m < 40 && !EXCLUDE.include?(e.definition.name) }
  container = model.entities.add_group
  container.name = NAME
  srcs.each { |e| container.entities.add_instance(e.definition, e.transformation) }
  container.transform!(Geom::Transformation.new(Geom::Vector3d.new(OFF.m, 0, 0)))
  container.make_unique

  # descend, uniquifying each level so the copy stops sharing definitions with
  # the original; keep direct refs because make_unique renames definitions
  find = lambda { |ents, w| ents.find { |e|
    (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) &&
    (e.name.to_s == w || e.definition.name == w) } }
  step = lambda { |ents, tr, w|
    n = find.call(ents, w); raise "missing #{w}" unless n
    n.make_unique
    [n, tr * n.transformation] }

  n88, t88 = step.call(container.entities, container.transformation, "Group#88")
  n30, t30 = step.call(n88.definition.entities, t88, "Group#30")
  pb,  tpb = step.call(n30.definition.entities, t30, "Union")
  n27, t27 = step.call(container.entities, container.transformation, "Group#27")
  n34, t34 = step.call(n27.definition.entities, t27, "Group#34")
  n28, t28 = step.call(n34.definition.entities, t34, "Group#28")
  pa,  tpa = step.call(n28.definition.entities, t28, "Group#4")
  ent, tent = step.call(n27.definition.entities, t27, "Group#207")

  nodes = { "PB" => [pb, tpb], "PA" => [pa, tpa] }
  report = ["rebuilt from original: #{srcs.length} elements"]

  rule = lambda { |rules, v| r = rules.find { |lo, hi, _| v >= lo && v < hi }; r ? r[2] : 0.0 }

  plan["openings"].group_by { |o| o["container"] }.each do |cont, ops|
    node, wtr = nodes[cont]
    inv = wtr.inverse
    verts = node.definition.entities.grep(Sketchup::Edge).flat_map(&:vertices).uniq
    vs = []; vecs = []; seen = {}; counts = {}
    ops.each do |o|
      ha = o["h_axis"]; na = o["n_axis"]; box = o["box"]; hits = 0
      verts.each do |v|
        next if seen[v.entityID]
        wp = v.position.transform(wtr)
        c = [wp.x.to_m - OFF, wp.y.to_m, wp.z.to_m]  # compare in ORIGINAL coords
        next unless c[ha].between?(box["h"][0], box["h"][1])
        next unless c[2].between?(box["z"][0], box["z"][1])
        next unless c[na].between?(box["n"][0], box["n"][1])
        dh = rule.call(o["h_rules"], c[ha]); dz = rule.call(o["z_rules"], c[2])
        next if dh.abs < 1e-9 && dz.abs < 1e-9
        seen[v.entityID] = true; hits += 1
        tp = Geom::Point3d.new(wp.x + (ha == 0 ? dh.m : 0), wp.y + (ha == 1 ? dh.m : 0), wp.z + dz.m)
        tl = tp.transform(inv)
        vs << v
        vecs << Geom::Vector3d.new(tl.x - v.position.x, tl.y - v.position.y, tl.z - v.position.z)
      end
      counts[o["id"]] = hits
    end
    # one atomic move: piecemeal transform_entities calls leave the reveal faces
    # temporarily non-planar and SketchUp splits/heals them, destroying the holes
    node.definition.entities.transform_by_vectors(vs, vecs)
    f = node.definition.entities.grep(Sketchup::Face)
    report << "#{cont}: moved=#{vs.size} #{counts.inspect} faces=#{f.count}"
  end

  s = plan["slab"]
  dz = s["z_to"] - s["z_from"]
  ev = ent.definition.entities.grep(Sketchup::Edge).flat_map(&:vertices).uniq
  moved = ev.select { |v| (v.position.transform(tent).z.to_m - s["z_from"]).abs < s["tol"] }
  ent.definition.entities.transform_by_vectors(moved, moved.map { Geom::Vector3d.new(0, 0, dz.m) })
  bb = ent.definition.bounds
  pts = (0..7).map { |i| bb.corner(i).transform(tent) }
  report << "entrepiso: moved=#{moved.size} thickness=#{(pts.map { |p| p.z.to_m }.max - pts.map { |p| p.z.to_m }.min).round(3)}"

  # ---- verify: report every architectural opening in the copy
  ffl = { "PB" => 0.62, "PA" => 3.57 }
  nodes.each do |cont, (node, tr)|
    found = []
    node.definition.entities.grep(Sketchup::Face).each do |f|
      n = f.normal.transform(tr)
      f.loops.each do |lp|
        next if lp.outer?
        vv = lp.vertices.map { |v| v.position.transform(tr) }
        xs = vv.map { |p| p.x.to_m - OFF }; ys = vv.map { |p| p.y.to_m }; zs = vv.map { |p| p.z.to_m }
        w = n.x.abs > 0.7 ? (ys.max - ys.min) : (xs.max - xs.min)
        next if w < 0.5 || (zs.max - zs.min) < 0.5
        found << sprintf("%.2fw x %.2fh sill %.2f @(%.2f,%.2f)", w, zs.max - zs.min, zs.min - ffl[cont], xs.min, ys.min)
      end
    end
    report << "#{cont} openings: #{found.sort.join(' | ')}"
  end

  model.commit_operation
  report.join("\n")
rescue => e
  model.abort_operation
  "ERROR: #{e.class}: #{e.message}\n#{e.backtrace.first(8).join("\n")}"
end
