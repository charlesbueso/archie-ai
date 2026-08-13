# Geometry + tree helpers. All public numbers are METERS; SketchUp's Ruby API
# is inches internally, so every boundary crossing converts explicitly.
module Archie
  module Util
    M_PER_IN = 0.0254

    def self.to_m(inches)
      (inches.to_f * M_PER_IN)
    end

    def self.to_in(meters)
      meters.to_f / M_PER_IN
    end

    def self.r(v, d = 3)
      f = v.to_f
      (f * (10**d)).round / (10**d).to_f
    end

    # Walk every Group / ComponentInstance, returning
    # [{pid:, entity:, transform:(world), path:, depth:, defn_name:, shared:}]
    # A fresh walk per request: persistent_ids are stable but transforms and
    # tree shape are not, and ~1000 containers takes ~ms.
    #
    # :shared is true when the entity's own definition OR any ancestor's
    # definition has more than one instance. Editing a shared entity's
    # definition would change every occurrence in the model, so Edit refuses
    # them. (The child's own count_instances alone misses the ancestor case —
    # the same child entity then appears at several world positions.)
    ROOT_PID = 0

    # The entities collection a container holds. The model root is exposed as
    # a pseudo-container so loose geometry is reachable by the same code.
    def self.ents_of(cont)
      cont[:entities] || cont[:entity].definition.entities
    end

    # World bbox of a container, root included.
    def self.cont_bbox(cont)
      return world_bbox(cont[:entity], cont[:transform]) unless cont[:root]
      bb = Sketchup.active_model.bounds
      { min:  [to_m(bb.min.x), to_m(bb.min.y), to_m(bb.min.z)].map { |v| r(v) },
        max:  [to_m(bb.max.x), to_m(bb.max.y), to_m(bb.max.z)].map { |v| r(v) },
        size: [to_m(bb.width), to_m(bb.height), to_m(bb.depth)].map { |v| r(v) } }
    end

    # NOTE: the model ROOT is included as a pseudo-container (pid 0).
    # Real models routinely keep whole walls as loose faces at root — one
    # downloaded house had 658 of them — and a walker that only visits groups
    # and components cannot see any of it. Root is never "shared", so it is
    # always editable.
    def self.containers(model, max_depth = 8)
      out = [{ pid: ROOT_PID, entity: nil, entities: model.entities,
               transform: Geom::Transformation.new, path: '(model root)',
               depth: -1, defn_name: '(root)', shared: false, root: true }]
      walk = nil
      walk = lambda do |ents, tr, depth, path, parent_shared|
        ents.each do |e|
          next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          wtr = tr * e.transformation
          name = e.name.to_s
          label = name.empty? ? e.definition.name : name
          shared = parent_shared || e.definition.count_instances > 1
          out << {
            pid: e.persistent_id, entity: e, transform: wtr,
            path: path + '/' + label, depth: depth, defn_name: e.definition.name,
            shared: shared
          }
          if depth < max_depth
            walk.call(e.definition.entities, wtr, depth + 1, path + '/' + label, shared)
          end
        end
      end
      walk.call(model.entities, Geom::Transformation.new, 0, '', false)
      out
    end

    def self.find_container(model, pid)
      containers(model).find { |c| c[:pid] == pid }
    end

    # The world transform of a container's PARENT. transform! applies in the
    # parent's coordinate space, so anchors and vectors must be converted
    # into it before use.
    def self.parent_transform(cont)
      cont[:transform] * cont[:entity].transformation.inverse
    end

    # Positional path to an entity: [i0, i1, ...] indices into successive
    # Entities collections. Needed by make_unique — copying a definition gives
    # its children brand-new persistent_ids, so a pid cannot be used to
    # re-find anything after a parent has been uniquified, but index position
    # survives because a definition copy preserves order.
    def self.index_path(model, pid, max_depth = 10)
      result = nil
      walk = nil
      walk = lambda do |ents, trail, depth|
        ents.to_a.each_with_index do |e, i|
          return if result
          next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          if e.persistent_id == pid
            result = trail + [i]
            return
          end
          walk.call(e.definition.entities, trail + [i], depth + 1) if depth < max_depth
        end
      end
      walk.call(model.entities, [], 0)
      result
    end

    # world [x,y,z] metres -> Geom::Point3d in the given space
    def self.pt(xyz, space_inverse = nil)
      p = Geom::Point3d.new(to_in(xyz[0]), to_in(xyz[1]), to_in(xyz[2]))
      space_inverse ? p.transform(space_inverse) : p
    end

    # World-space bbox of a container as {min:[m], max:[m], size:[m]}.
    def self.world_bbox(entity, wtr)
      bb = entity.definition.bounds
      xs = []; ys = []; zs = []
      (0..7).each do |i|
        p = bb.corner(i).transform(wtr)
        xs << p.x; ys << p.y; zs << p.z
      end
      {
        min:  [to_m(xs.min), to_m(ys.min), to_m(zs.min)].map { |v| r(v) },
        max:  [to_m(xs.max), to_m(ys.max), to_m(zs.max)].map { |v| r(v) },
        size: [to_m(xs.max - xs.min), to_m(ys.max - ys.min), to_m(zs.max - zs.min)].map { |v| r(v) }
      }
    end

    # World bbox computed from ACTUAL vertex positions instead of
    # definition.bounds.
    #
    # definition.bounds is cached and does NOT refresh until the enclosing
    # operation commits. Since verification now runs *inside* the operation
    # (so a bad edit can be rolled back), reading the cached bbox reports the
    # pre-edit geometry and rolls back perfectly good edits. Any check that
    # happens between start_operation and commit_operation must use this.
    def self.world_bbox_live(entity, wtr)
      xs = []; ys = []; zs = []
      deep_vertex_groups(entity, wtr).each do |g|
        g[:verts].each do |v|
          p = v.position.transform(g[:transform])
          xs << p.x; ys << p.y; zs << p.z
        end
      end
      return world_bbox(entity, wtr) if xs.empty?
      { min:  [to_m(xs.min), to_m(ys.min), to_m(zs.min)].map { |v| r(v) },
        max:  [to_m(xs.max), to_m(ys.max), to_m(zs.max)].map { |v| r(v) },
        size: [to_m(xs.max - xs.min), to_m(ys.max - ys.min), to_m(zs.max - zs.min)].map { |v| r(v) } }
    end

    # All unique vertices of a definition's top-level edges.
    # NOTE: Vertex is NOT a top-level member of Entities — entities.grep
    # (Sketchup::Vertex) returns [], silently. Reach them through edges.
    def self.vertices_of(defn)
      defn.entities.grep(Sketchup::Edge).flat_map(&:vertices).uniq
    end

    # Vertices of a container AND every nested container inside it, bucketed
    # by the Entities collection that owns them — transform_by_vectors only
    # accepts vertices belonging to the collection it is called on.
    #
    # BUG-07: slabs are often detected by bounding box at one level while
    # their faces live a level deeper, so a direct-entities-only sweep finds
    # no vertices and a listed slab turns out to be uneditable.
    #
    # Returns [{entities:, transform:(world), verts:[], shared: bool}]
    def self.deep_vertex_groups(entity, wtr, depth = 0, max_depth = 6)
      out = []
      defn = entity.definition
      verts = vertices_of(defn)
      unless verts.empty?
        out << { entities: defn.entities, transform: wtr, verts: verts,
                 shared: defn.count_instances > 1 }
      end
      return out if depth >= max_depth
      defn.entities.each do |e|
        next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        out.concat(deep_vertex_groups(e, wtr * e.transformation, depth + 1, max_depth))
      end
      out
    end
  end
end
