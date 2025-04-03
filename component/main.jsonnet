// main template for espejote
local helper = import 'helper.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local espejote = import 'lib/espejote.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local roles = import 'roles.libsonnet';
local inv = kap.inventory();

// The hiera parameters for the component
local params = inv.parameters.espejote;
local isOpenshift = std.member([ 'openshift4', 'oke' ], inv.parameters.facts.distribution);

// Namespace

local namespace = {
  apiVersion: 'v1',
  kind: 'Namespace',
  metadata: {
    labels: {
      'app.kubernetes.io/name': params.namespace,
      name: params.namespace,
      // Configure the namespaces so that the OCP4 cluster-monitoring
      // Prometheus can find the servicemonitors and rules.
      [if isOpenshift then 'openshift.io/cluster-monitoring']: 'true',
    },
    name: params.namespace,
  },
};

// Aggregated ClusterRole

local aggregatedClusterRole = {
  apiVersion: 'rbac.authorization.k8s.io/v1',
  kind: 'ClusterRole',
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
local alerts = {
  apiVersion: 'monitoring.coreos.com/v1',
  kind: 'PrometheusRule',
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

local jsonnetLibrary(jlName) = espejote.jsonnetLibrary(jlName, params.namespace) + com.makeMergeable(params.jsonnetLibraries[jlName]);

// Managed Resources

local managedResource(mrName) =
  espejote.managedResource(helper.namespacedName(mrName).name, helper.namespacedName(mrName).namespace) + com.makeMergeable({
    spec+: {
      serviceAccountRef: {
        name: helper.serviceAccountName(mrName),
      },
    },
  }) + com.makeMergeable({
    [key]: params.managedResources[mrName][key]
    for key in std.objectFields(params.managedResources[mrName])
    if std.member([ 'metadata', 'spec' ], key)
  });

local serviceAccount(mrName) = {
  apiVersion: 'v1',
  kind: 'ServiceAccount',
  metadata: {
    labels: {
      'app.kubernetes.io/name': helper.serviceAccountName(mrName),
      'managedresource.espejote.io/name': helper.namespacedName(mrName).name,
    },
    name: helper.serviceAccountName(mrName),
    namespace: helper.namespacedName(mrName).namespace,
  },
};

// Roles and RoleBindings

local clusterRoleFromRules(mrName) = if std.get(params.managedResources[mrName], '_clusterRules', null) != null then
  local rules = params.managedResources[mrName]._clusterRules;
  local role = roles.generateRole(mrName, rules, true);
  local roleBinding = roles.generateBinding(mrName, role.metadata.name, true);
  [ role, roleBinding ] else [];

local roleFromRules(mrName) = if std.get(params.managedResources[mrName], '_rules', null) != null then
  local rules = params.managedResources[mrName]._rules;
  local role = roles.generateRole(mrName, rules, false);
  local roleBinding = roles.generateBinding(mrName, role.metadata.name, false);
  [ role, roleBinding ] else [];

local clusterRoleBinding(mrName) = [
  roles.generateBinding(mrName, roleName, true)
  for roleName in com.renderArray(std.get(params.managedResources[mrName], '_clusterRoles', []))
];

local roleBinding(mrName) = [
  roles.generateBinding(mrName, roleName, false)
  for roleName in com.renderArray(std.get(params.managedResources[mrName], '_roles', []))
];

// Define outputs below
{
  '00_namespace': namespace,
  '20_aggregated_cluster_role': aggregatedClusterRole,
  '30_alerts': alerts,
} + {
  ['50_jl_%s' % helper.namespacedName(name).name]: jsonnetLibrary(name)
  for name in std.objectFields(params.jsonnetLibraries)
} + {
  ['60_mr_%s_%s' % [ helper.namespacedName(name).namespace, helper.namespacedName(name).name ]]:
    local manifest = managedResource(name);
    [ manifest, serviceAccount(name) ]
    + clusterRoleFromRules(name)
    + roleFromRules(name)
    + clusterRoleBinding(name)
    + roleBinding(name)
    + espejote.readingRbacObjects(manifest)
  for name in std.objectFields(params.managedResources)
}
