# blend_mesh.py -- run inside Blender, write one mesh as text the importer reads.
#
#   blender --background FILE.blend --python tools/blend_mesh.py -- OUT TRIS [OBJ]
#
# Blender is here for the same reason `cc` is: reading a .blend means reading a
# format whose only real specification is Blender itself, and `id` has no file
# I/O to read it with anyway. What comes out is deliberately dull -- integers,
# one per line, in the engine's own units -- so that everything above it (the
# palette of face colours, the model's shape in idml, the diagnostics) happens
# in `id` where the rest of the engine lives.
#
# What this does that the `id` side cannot:
#
#   * evaluates modifiers and applies each object's world transform, so what is
#     exported is what the scene looks like, not what the mesh datablock holds
#   * triangulates (the rasteriser takes triangles and nothing else)
#   * decimates to a triangle budget, because a real architectural scene is
#     130 000 triangles and a software rasteriser at 320x200 is not
#   * resolves each polygon's material to one flat sRGB colour, which is all a
#     flat/Gouraud rasteriser can honour (IDML_GAME.md section 3)
#
# The whole scene is joined into one model by default: idem's `model` is a bag
# of triangles, and a showroom is one piece of level geometry. Pass an object
# name as the third argument to export just that object.

import sys, math
import bpy

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
out_path = argv[0] if argv else "/dev/stdout"
budget = int(argv[1]) if len(argv) > 1 else 2000
only = argv[2] if len(argv) > 2 else None
name = argv[3] if len(argv) > 3 else "imported"


def srgb(c):
    """Linear float -> 8-bit sRGB. Blender stores base colours linear; the
    engine's colours are what a screen shows, so the transfer function has to be
    applied or every imported model comes out visibly too dark."""
    c = max(0.0, min(1.0, c))
    s = 12.92 * c if c <= 0.0031308 else 1.055 * (c ** (1 / 2.4)) - 0.055
    return max(0, min(255, int(round(s * 255))))


def material_colour(mat):
    """One flat colour per material: the Principled BSDF's base colour if there
    is one, the viewport colour otherwise. An emission shader reports its own
    colour, so a light fitting does not import as black."""
    if mat is None:
        return (160, 160, 160)
    if mat.use_nodes and mat.node_tree:
        for want in ("Base Color", "Color"):
            for node in mat.node_tree.nodes:
                inp = node.inputs.get(want) if hasattr(node, "inputs") else None
                if inp is not None and not inp.is_linked and len(inp.default_value) >= 3:
                    v = inp.default_value
                    return (srgb(v[0]), srgb(v[1]), srgb(v[2]))
    v = mat.diffuse_color
    return (srgb(v[0]), srgb(v[1]), srgb(v[2]))


def mesh_objects():
    objs = [o for o in bpy.data.objects if o.type == "MESH" and not o.hide_render]
    if only:
        objs = [o for o in objs if o.name == only]
        if not objs:
            sys.stderr.write("blend_mesh: no mesh object named %r\n" % only)
            sys.exit(2)
    return objs


# ---------------------------------------------------------------------------
# Decimate to the budget before triangulating anything, because collapsing a
# quad mesh gives a far better result than collapsing the triangles it was
# turned into. The ratio is computed over the whole selection so that one huge
# object cannot eat the entire budget and leave the rest at one triangle each.

objs = mesh_objects()
total_tris = 0
for o in objs:
    m = o.evaluated_get(bpy.context.evaluated_depsgraph_get()).to_mesh()
    total_tris += sum(len(p.vertices) - 2 for p in m.polygons)
    o.evaluated_get(bpy.context.evaluated_depsgraph_get()).to_mesh_clear()

ratio = 1.0 if total_tris <= budget else max(0.002, budget / float(total_tris))
sys.stderr.write("blend_mesh: %d objects, %d triangles, decimate ratio %.4f\n"
                 % (len(objs), total_tris, ratio))

if ratio < 1.0:
    for o in objs:
        mod = o.modifiers.new(name="idem_decimate", type="DECIMATE")
        mod.ratio = ratio

# ---------------------------------------------------------------------------
# Collect. Vertices are shared per object only -- welding across objects would
# cost a global hash for no benefit, since the importer does not care and the
# engine draws triangles, not a connected surface.

verts = []
faces = []
depsgraph = bpy.context.evaluated_depsgraph_get()

for o in objs:
    ev = o.evaluated_get(depsgraph)
    mesh = ev.to_mesh()
    mesh.calc_loop_triangles()
    mat = o.matrix_world
    base = len(verts)
    for v in mesh.vertices:
        w = mat @ v.co
        verts.append((w.x, w.y, w.z))
    cols = [material_colour(ms.material) for ms in o.material_slots] or [material_colour(None)]
    for t in mesh.loop_triangles:
        c = cols[t.material_index] if t.material_index < len(cols) else cols[0]
        faces.append((base + t.vertices[0], base + t.vertices[1], base + t.vertices[2],
                      (c[0] << 16) | (c[1] << 8) | c[2]))
    ev.to_mesh_clear()

# Blender is Z-up and right-handed; idem is Y-up with -Z forward (ARCHITECTURE
# section 4 and gfx/d3/view/). So (x, y, z)_blender -> (x, z, -y)_idem. Doing it
# here rather than in `id` means no game ever carries a per-asset axis flag.
def to_idem(v):
    return (int(round(v[0] * 1000)), int(round(v[2] * 1000)), int(round(-v[1] * 1000)))


with open(out_path, "w") as f:
    f.write("model %s %d %d\n" % (name, len(verts), len(faces)))
    for v in verts:
        x, y, z = to_idem(v)
        f.write("%d %d %d\n" % (x, y, z))
    for a, b, c, col in faces:
        f.write("%d %d %d %d\n" % (a, b, c, col))

sys.stderr.write("blend_mesh: wrote %d verts, %d triangles to %s\n"
                 % (len(verts), len(faces), out_path))
