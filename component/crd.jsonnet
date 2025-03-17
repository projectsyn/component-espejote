// main template for cm-hetznercloud
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

// The hiera parameters for the component
local params = inv.parameters.espejote;

local crd = com.Kustomization(
  'https://github.com/vshn/espejote/config/crd',
  params.manifestVersion,
);

crd
