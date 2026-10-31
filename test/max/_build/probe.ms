-- probe: verify primitive pivot conventions and layer API on this Max build
(
  local out = ""
  local b = Box length:20 width:10 height:10 pos:[0,0,0]
  out += "box pos=" + (b.pos as string) + " min=" + (b.min as string) + " max=" + (b.max as string) + "\n"
  local c = Cylinder radius:5 height:10 pos:[40,0,0]
  out += "cyl pos=" + (c.pos as string) + " min=" + (c.min as string) + " max=" + (c.max as string) + "\n"
  local p = Plane length:20 width:20 pos:[80,0,0]
  out += "plane pos=" + (p.pos as string) + " min=" + (p.min as string) + " max=" + (p.max as string) + "\n"

  -- instance clone keeps geometry shared?
  local i1 = instance b
  i1.pos = [0,40,0]
  out += "instance ok, basefaces=" + ((getPolygonCount b)[1] as string) + "\n"

  -- layer api
  local lay = LayerManager.newLayerFromName "PROBE_LAYER"
  lay.addNode b
  out += "layer=" + lay.name + " nodes=" + (lay.getNumNodes() as string) + "\n"

  -- renderer / arnold availability
  out += "renderer=" + (renderers.current as string) + "\n"
  out += "vrayLoaded=" + ((try ((classof (VRayMtl())) as string) catch ("no")) as string) + "\n"
  out += "physicalMat=" + ((try ((classof (PhysicalMaterial())) as string) catch ("no")) as string) + "\n"
  out += "arnoldTex=" + ((try ((classof (ArnoldShader())) as string) catch ("no")) as string) + "\n"

  delete $Box* ; delete $Cylinder* ; delete $Plane*
  LayerManager.deleteLayerByName "PROBE_LAYER"
  out
)
