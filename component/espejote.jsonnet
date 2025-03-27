// main template for cm-hetznercloud
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

// The hiera parameters for the component
local params = inv.parameters.espejote;

// CRDs

local crd = com.Kustomization(
  'https://github.com/vshn/espejote/config/crd',
  params.manifestVersion,
);

// Controller

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
    namespace: params.namespace,
    patchesStrategicMerge: [
      'rm-namespace.yaml',
      std.manifestJson({
        apiVersion: 'apps/v1',
        kind: 'Deployment',
        metadata: {
          name: 'controller-manager',
          namespace: 'system',
        },
        spec: {
          template: {
            spec: {
              containers: [
                {
                  name: 'kube-rbac-proxy',
                  resources: params.resources.rbac_proxy,
                },
                {
                  name: 'manager',
                  resources: params.resources.espejote,
                },
              ],
            },
          },
        },
      }),
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
