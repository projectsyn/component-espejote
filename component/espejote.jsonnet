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
    // Inner kustomization layers are immutable, so we need to re-replace the namespace after changing it in an outer layer
    replacements: [
      {
        source: {
          kind: 'Service',
          version: 'v1',
          name: 'controller-manager-metrics-service',
          fieldPath: 'metadata.name',
        },
        targets: [
          {
            select: {
              kind: 'Certificate',
              group: 'cert-manager.io',
              version: 'v1',
              name: 'metrics-certs',
            },
            fieldPaths: [
              'spec.dnsNames.0',
              'spec.dnsNames.1',
            ],
            options: {
              delimiter: '.',
              index: 0,
              create: true,
            },
          },
          {
            select: {
              kind: 'ServiceMonitor',
              group: 'monitoring.coreos.com',
              version: 'v1',
              name: 'controller-manager-metrics-monitor',
            },
            fieldPaths: [
              'spec.endpoints.0.tlsConfig.serverName',
            ],
            options: {
              delimiter: '.',
              index: 0,
              create: true,
            },
          },
        ],
      },
      {
        source: {
          kind: 'Service',
          version: 'v1',
          name: 'controller-manager-metrics-service',
          fieldPath: 'metadata.namespace',
        },
        targets: [
          {
            select: {
              kind: 'Certificate',
              group: 'cert-manager.io',
              version: 'v1',
              name: 'metrics-certs',
            },
            fieldPaths: [
              'spec.dnsNames.0',
              'spec.dnsNames.1',
            ],
            options: {
              delimiter: '.',
              index: 1,
              create: true,
            },
          },
          {
            select: {
              kind: 'ServiceMonitor',
              group: 'monitoring.coreos.com',
              version: 'v1',
              name: 'controller-manager-metrics-monitor',
            },
            fieldPaths: [
              'spec.endpoints.0.tlsConfig.serverName',
            ],
            options: {
              delimiter: '.',
              index: 1,
              create: true,
            },
          },
        ],
      },
      {
        source: {
          kind: 'Service',
          version: 'v1',
          name: 'webhook-service',
          fieldPath: '.metadata.name',
        },
        targets: [
          {
            select: {
              kind: 'Certificate',
              group: 'cert-manager.io',
              version: 'v1',
              name: 'serving-cert',
            },
            fieldPaths: [
              '.spec.dnsNames.0',
              '.spec.dnsNames.1',
            ],
            options: {
              delimiter: '.',
              index: 0,
              create: true,
            },
          },
        ],
      },
      {
        source: {
          kind: 'Service',
          version: 'v1',
          name: 'espejote-webhook-service',
          fieldPath: '.metadata.namespace',
        },
        targets: [
          {
            select: {
              kind: 'Certificate',
              group: 'cert-manager.io',
              version: 'v1',
              name: 'espejote-serving-cert',
            },
            fieldPaths: [
              '.spec.dnsNames.0',
              '.spec.dnsNames.1',
            ],
            options: {
              delimiter: '.',
              index: 1,
              create: true,
            },
          },
        ],
      },
      {
        source: {
          kind: 'Certificate',
          group: 'cert-manager.io',
          version: 'v1',
          name: 'espejote-serving-cert',
          fieldPath: '.metadata.namespace',
        },
        targets: [
          {
            select: {
              kind: 'ValidatingWebhookConfiguration',
            },
            fieldPaths: [
              '.metadata.annotations.[cert-manager.io/inject-ca-from]',
            ],
            options: {
              delimiter: '/',
              index: 0,
              create: true,
            },
          },
        ],
      },
      {
        source: {
          kind: 'Certificate',
          group: 'cert-manager.io',
          version: 'v1',
          name: 'espejote-serving-cert',
          fieldPath: '.metadata.name',
        },
        targets: [
          {
            select: {
              kind: 'ValidatingWebhookConfiguration',
            },
            fieldPaths: [
              '.metadata.annotations.[cert-manager.io/inject-ca-from]',
            ],
            options: {
              delimiter: '/',
              index: 1,
              create: true,
            },
          },
        ],
      },
      {
        source: {
          kind: 'Certificate',
          group: 'cert-manager.io',
          version: 'v1',
          name: 'espejote-serving-cert',
          fieldPath: '.metadata.namespace',
        },
        targets: [
          {
            select: {
              kind: 'MutatingWebhookConfiguration',
            },
            fieldPaths: [
              '.metadata.annotations.[cert-manager.io/inject-ca-from]',
            ],
            options: {
              delimiter: '/',
              index: 0,
              create: true,
            },
          },
        ],
      },
      {
        source: {
          kind: 'Certificate',
          group: 'cert-manager.io',
          version: 'v1',
          name: 'espejote-serving-cert',
          fieldPath: '.metadata.name',
        },
        targets: [
          {
            select: {
              kind: 'MutatingWebhookConfiguration',
            },
            fieldPaths: [
              '.metadata.annotations.[cert-manager.io/inject-ca-from]',
            ],
            options: {
              delimiter: '/',
              index: 1,
              create: true,
            },
          },
        ],
      },
    ],

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
