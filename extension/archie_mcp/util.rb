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
    def self.containers(model, max_depth = 8)
      out = []
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
