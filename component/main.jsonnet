// main template for espejote
local com = import 'lib/commodore.libjsonnet';
local espejote = import 'lib/espejote.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

// The hiera parameters for the component
local params = inv.parameters.espejote;
local isOpenshift = std.member([ 'openshift4', 'oke' ], inv.parameters.facts.distribution);

// Helpers: Names

local namespacedName(name, namespace='') = {
  local namespacedName = std.splitLimit(name, '/', 1),
  local ns = if namespace != '' then namespace else params.namespace,
  namespace: if std.length(namespacedName) > 1 then namespacedName[0] else ns,
  name: if std.length(namespacedName) > 1 then namespacedName[1] else namespacedName[0],
};

local serviceAccountName(name) = 'espejote:%s' % std.get(
  params.managedResources[name].spec,
  'serviceAccountRef',
  { name: namespacedName(name).name },
).name;

local hashedName(name, hidden=[]) =
  // Ensure the total length of the name is less than 63 characters
  // 63 - `espejote` - 2x `:` - hash length = 38
  local unhashed = std.substr(std.join(':', name), 0, 38);
  local toHash = std.join(':', name + hidden);
  local hashed = std.substr(std.md5(toHash), 0, 15);
  'espejote:%(unhashed)s:%(hashed)s' % [ unhashed, hashed ];

// Helpers: Generate Roles and RoleBindings

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

// Namespace

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

// Aggregated ClusterRole

local aggregatedClusterRole = kube._Object('rbac.authorization.k8s.io/v1', 'ClusterRole', 'espejote-crds-cluster-reader') {
  metadata: {
    labels: {
      'app.kubernetes.io/name': 'espejote-crds-cluster-reader',
      'rbac.authorization.k8s.io/aggregate-to-cluster-reader': 'true',
    },
    name: 'espejote-crds-cluster-reader',
  },
  rules: [
    {
      apiGroups: [ 'espejote.io' ],
      resources: [ '*' ],
      verbs: [ 'get', 'list', 'watch' ],
    },
  ],
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

// Jsonnet Libraries

local jsonnetLibrary(name) = espejote.jsonnetLibrary(name, params.namespace) + com.makeMergeable(params.jsonnetLibraries[name]);

// Managed Resources

local managedResource(name) = [
  espejote.managedResource(namespacedName(name).name, namespacedName(name).namespace) + com.makeMergeable({
    spec+: {
      serviceAccountRef: {
        name: serviceAccountName(name),
      },
    },
  }) + com.makeMergeable({
    [key]: params.managedResources[name][key]
    for key in std.objectFields(params.managedResources[name])
    if std.member([ 'metadata', 'spec' ], key)
  }),
  {
    apiVersion: 'v1',
    kind: 'ServiceAccount',
    metadata: {
      labels: {
        'app.kubernetes.io/name': serviceAccountName(name),
        'managedresource.espejote.io/name': namespacedName(name, namespace).name,
      },
      name: serviceAccountName(name),
      namespace: namespacedName(name).namespace,
    },
  },
];

// Roles and RoleBindings

local clusterRoleFromRules(name) = if std.get(params.managedResources[name], '_clusterRules', null) != null then [
  processRole({
    local generatedName = hashedName([ namespacedName(name).namespace, namespacedName(name).name ], [ 'clusterrole' ]),
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'ClusterRole',
    metadata: {
      labels: {
        'app.kubernetes.io/name': generatedName,
        'managedresource.espejote.io/name': namespacedName(name, namespace).name,
        'managedresource.espejote.io/namespace': namespacedName(name, namespace).namespace,
      },
      name: generatedName,
    },
    rules_: params.managedResources[name]._clusterRules,
  }),
  processRoleBinding({
    local generatedName = hashedName([ namespacedName(name).namespace, namespacedName(name).name ], [ 'clusterrolebinding' ]),
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'ClusterRoleBinding',
    metadata: {
      labels: {
        'app.kubernetes.io/name': generatedName,
        'managedresource.espejote.io/name': namespacedName(name, namespace).name,
        'managedresource.espejote.io/namespace': namespacedName(name, namespace).namespace,
      },
      name: generatedName,
    },
    clusterRole_: hashedName([ namespacedName(name).namespace, namespacedName(name).name ], [ 'clusterrole' ]),
    subjects: [ {
      kind: 'ServiceAccount',
      name: serviceAccountName(name),
      namespace: namespacedName(name).namespace,
    } ],
  }),
] else [];

local roleFromRules(name) = if std.get(params.managedResources[name], '_rules', null) != null then [
  processRole({
    local generatedName = hashedName([ namespacedName(name).name ], [ namespacedName(name).namespace, 'role' ]),
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'Role',
    metadata: {
      labels: {
        'app.kubernetes.io/name': generatedName,
        'managedresource.espejote.io/name': namespacedName(name, namespace).name,
      },
      name: generatedName,
      namespace: namespacedName(name).namespace,
    },
    rules_: params.managedResources[name]._rules,
  }),
  processRoleBinding({
    local generatedName = hashedName([ namespacedName(name).name ], [ namespacedName(name).namespace, 'rolebinding' ]),
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'RoleBinding',
    metadata: {
      labels: {
        'app.kubernetes.io/name': generatedName,
        'managedresource.espejote.io/name': namespacedName(name, namespace).name,
      },
      name: generatedName,
      namespace: namespacedName(name).namespace,
    },
    role_: hashedName([ namespacedName(name).name ], [ namespacedName(name).namespace, 'role' ]),
    subjects: [ {
      kind: 'ServiceAccount',
      name: serviceAccountName(name),
      namespace: namespacedName(name).namespace,
    } ],
  }),
] else [];

local clusterRoleBinding(name) = if std.get(params.managedResources[name], '_clusterRoles', null) != null then [
  processRoleBinding({
    local generatedName = hashedName([ namespacedName(name).namespace, namespacedName(name).name ], [ 'clusterrolebinding' ]),
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'ClusterRoleBinding',
    metadata: {
      labels: {
        'app.kubernetes.io/name': generatedName,
        'managedresource.espejote.io/name': namespacedName(name, namespace).name,
        'managedresource.espejote.io/namespace': namespacedName(name, namespace).namespace,
      },
      name: generatedName,
    },
    clusterRole_: ref,
    subjects: [ {
      kind: 'ServiceAccount',
      name: serviceAccountName(name),
      namespace: namespacedName(name).namespace,
    } ],
  })
  for ref in std.get(params.managedResources[name], '_clusterRoles', [])
] else [];

local roleBinding(name) = if std.get(params.managedResources[name], '_roles', null) != null then [
  processRoleBinding({
    local generatedName = hashedName([ namespacedName(name).namespace, namespacedName(name).name ], [ 'rolebinding' ]),
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'RoleBinding',
    metadata: {
      labels: {
        'app.kubernetes.io/name': generatedName,
        'managedresource.espejote.io/name': namespacedName(name, namespace).name,
      },
      name: generatedName,
    },
    role_: ref,
    subjects: [ {
      kind: 'ServiceAccount',
      name: serviceAccountName(name),
      namespace: namespacedName(name).namespace,
    } ],
  })
  for ref in std.get(params.managedResources[name], '_roles', [])
] else [];

// Define outputs below
{
  '00_namespace': namespace,
  '20_aggregated_cluster_role': aggregatedClusterRole,
  '30_alerts': alerts,
} + {
  ['50_jl_%s' % namespacedName(name).name]: jsonnetLibrary(name)
  for name in std.objectFields(params.jsonnetLibraries)
} + {
  ['60_mr_%s_%s' % [ namespacedName(name).namespace, namespacedName(name).name ]]:
    managedResource(name)
    + clusterRoleFromRules(name)
    + roleFromRules(name)
    + clusterRoleBinding(name)
    + roleBinding(name)
  for name in std.objectFields(params.managedResources)
}
