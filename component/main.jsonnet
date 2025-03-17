// main template for espejote
local com = import 'lib/commodore.libjsonnet';
local espejote = import 'lib/espejote.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

// The hiera parameters for the component
local params = inv.parameters.espejote;
local isOpenshift = std.member([ 'openshift', 'oke' ], inv.parameters.facts.distribution);

local namespace = kube.Namespace(params.namespace) {
  metadata+: {
    labels+: {
      'app.kubernetes.io/name': params.namespace,
      // Configure the namespaces so that the OCP4 cluster-monitoring
      // Prometheus can find the servicemonitors and rules.
      [if isOpenshift then 'openshift.io/cluster-monitoring']: 'true',
    },
  },
};

// Alerts

local alertFilter(field) = params.alerts[field].enabled == true;
local alertMap(field) = params.alerts[field].rule {
  alert: field,
  annotations+: {
    runbook_url: 'https://hub.syn.tools/component-espejote/runbooks/%s.html' % [ field ],
  },
  labels+: {
    syn: 'true',
    syn_component: 'espejote',
  },
};
local alerts = kube._Object('monitoring.coreos.com/v1', 'PrometheusRule', 'espejote-alerts') {
  metadata: {
    labels: {
      'app.kubernetes.io/name': 'espejote-alerts',
    },
    name: 'espejote-alerts',
    namespace: params.namespace,
  },
  spec: {
    groups: [
      {
        name: 'espejote',
        rules: std.filterMap(alertFilter, alertMap, std.objectFields(params.alerts)),
      },
    ],
  },
};

// Custom Resources

local namespacedName(name, namespace='') = {
  local namespacedName = std.splitLimit(name, '/', 1),
  local ns = if namespace != '' then namespace else params.namespace,
  namespace: if std.length(namespacedName) > 1 then namespacedName[0] else ns,
  name: if std.length(namespacedName) > 1 then namespacedName[1] else namespacedName[0],
};

local serviceAccountName(name) = std.get(
  params.managedResources[name].spec,
  'serviceAccountRef',
  namespacedName(name).name,
);

local managedResources = [
  espejote.managedResource(namespacedName(name).name, namespacedName(name).namespace) + com.makeMergeable({
    spec+: {
      serviceAccountRef: serviceAccountName(name),
    },
  }) + com.makeMergeable({
    [key]: params.managedResources[name][key]
    for key in std.objectFields(params.managedResources[name])
    if std.member([ 'metadata', 'spec' ], key)
  })
  for name in std.objectFields(params.managedResources)
];

local serviceAccounts = std.uniq([
  kube._Object('rbac.authorization.k8s.io/v1', 'ServiceAccount', namespacedName(name).name) {
    metadata: {
      labels: {
        'app.kubernetes.io/name': serviceAccountName(name),
      },
      name: serviceAccountName(name),
      namespace: namespacedName(name).namespace,
    },
  }
  for name in std.objectFields(params.managedResources)
]);

local jsonnetLibraries = [
  espejote.jsonnetLibrary(namespacedName(name).name, namespacedName(name).namespace) + com.makeMergeable(params.jsonnetLibraries[name])
  for name in std.objectFields(params.jsonnetLibraries)
];

// Roles and RoleBindings

local hashedName(prefix, values) = '%s-%s' % [ prefix, std.md5(std.join('-', values)) ];

local processRole(r) = r {
  local extraRules = std.objectValues(
    com.getValueOrDefault(r, 'rules_', {})
  ),
  rules_:: null,
  rules+: [ {
    apiGroups: com.renderArray(rule.apiGroups),
    resources: com.renderArray(rule.resources),
    verbs: com.renderArray(rule.verbs),
  } for rule in extraRules ],
};
local roles = std.uniq([
  processRole(r)
  for r in [
    kube._Object('rbac.authorization.k8s.io/v1', 'Role', namespacedName(name).name) {
      metadata: {
        labels: {
          'app.kubernetes.io/name': hashedName('espejote', [ namespacedName(name).name, 'role' ]),
        },
        name: hashedName('espejote', [ namespacedName(name).name, 'role' ]),
        namespace: namespacedName(name).namespace,
      },
      rules_: params.managedResources[name].rules,
    }
    for name in std.objectFields(params.managedResources)
    if std.get(params.managedResources[name], 'rules', null) != null
  ]
]);

local processRoleBinding(rb) = rb {
  local rbNs = com.getValueOrDefault(rb.metadata, 'namespace', ''),

  roleRef+:
    {
      apiGroup: 'rbac.authorization.k8s.io',
    }
    +
    if std.objectHas(rb, 'role_') && std.objectHas(rb, 'clusterRole_') then error 'cannot specify both "role_" and "clusterRole_"'
    else if std.objectHas(rb, 'role_') then {
      kind: 'Role',
      name: rb.role_,
    }
    else if std.objectHas(rb, 'clusterRole_') then {
      kind: 'ClusterRole',
      name: rb.clusterRole_,
    }
    else {},

  role_:: null,
  clusterRole_:: null,
};
local roleBindings = [
  processRoleBinding(rb)
  for rb in [
    kube._Object('rbac.authorization.k8s.io/v1', 'RoleBinding', 'default') {
      metadata: {
        labels: {
          'app.kubernetes.io/name': hashedName('espejote', [ namespacedName(name).name, 'rules' ]),
        },
        name: hashedName('espejote', [ namespacedName(name).name, 'rules' ]),
        namespace: namespacedName(name).namespace,
      },
      role_: hashedName('espejote', [ namespacedName(name).name, 'role' ]),
      subjects: [ {
        kind: 'ServiceAccount',
        name: serviceAccountName(name),
        namespace: namespacedName(name).namespace,
      } ],
    }
    for name in std.objectFields(params.managedResources)
    if std.get(params.managedResources[name], 'rules', null) != null
  ] + [
    kube._Object('rbac.authorization.k8s.io/v1', 'RoleBinding', 'default') {
      metadata: {
        labels: {
          'app.kubernetes.io/name': hashedName('espejote', [ namespacedName(name).name, 'clusterrole', ref ]),
        },
        name: hashedName('espejote', [ namespacedName(name).name, 'clusterrole', ref ]),
        namespace: namespacedName(name).namespace,
      },
      clusterRole_: ref,
      subjects: [ {
        kind: 'ServiceAccount',
        name: serviceAccountName(name),
        namespace: namespacedName(name).namespace,
      } ],
    }
    for name in std.objectFields(params.managedResources)
    for ref in std.get(params.managedResources[name], 'clusterRoles', [])
  ] + [
    kube._Object('rbac.authorization.k8s.io/v1', 'RoleBinding', 'default') {
      metadata: {
        labels: {
          'app.kubernetes.io/name': hashedName('espejote', [ namespacedName(name).name, 'role', ref ]),
        },
        name: hashedName('espejote', [ namespacedName(name).name, 'role', ref ]),
        namespace: namespacedName(name).namespace,
      },
      role_: ref,
      subjects: [ {
        kind: 'ServiceAccount',
        name: serviceAccountName(name),
        namespace: namespacedName(name).namespace,
      } ],
    }
    for name in std.objectFields(params.managedResources)
    for ref in std.get(params.managedResources[name], 'roles', [])
  ]
  if rb != null
];

// Define outputs below
{
  '00_namespace': namespace,
  '20_alerts': alerts,
  '30_jsonnet_libraries': jsonnetLibraries,
  '60_managed_resources': managedResources,
  '61_service_accounts': serviceAccounts,
  '62_roles': roles,
  '63_role_bindings': roleBindings,
}
