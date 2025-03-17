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

local espejote = com.Kustomization(
  'https://github.com/vshn/espejote/config/default',
  params.manifestVersion,
  {
    'ghcr.io/vshn/espejote': {
      newTag: params.images.espejote.tag,
      newName: '%(registry)s/%(repository)s' % params.images.espejote,
    },
  },
  {
    patchesStrategicMerge: [
      'rm-namespace.yaml',
    ],
  } + com.makeMergeable(params.kustomizeInput),
) {
  'rm-namespace': {
    '$patch': 'delete',
    apiVersion: 'v1',
    kind: 'Namespace',
    metadata: {
      name: 'system',
    },
  },
};

espejote
