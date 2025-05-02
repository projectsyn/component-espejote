// main template for espejote
local com = import 'lib/commodore.libjsonnet';
local espejote = import 'lib/espejote.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local helper = import 'libsonnet';
local inv = kap.inventory();

// The hiera parameters for the component
local params = inv.parameters.espejote;
local isOpenshift = std.member([ 'openshift4', 'oke' ], inv.parameters.facts.distribution);

local namespacedName(name, namespace=params.namespace) = {
  local namespacedName = std.splitLimit(name, '/', 1),
  namespace: if std.length(namespacedName) > 1 then namespacedName[0] else namespace,
  name: if std.length(namespacedName) > 1 then namespacedName[1] else namespacedName[0],
};

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

local serviceAccountName(name) =
  espejote.serviceAccountNameForManagedResource(
    params.managedResources[name].spec,
    'espejote-%s' % namespacedName(name).name
  );

// Jsonnet Libraries

local jsonnetLibrary(jlName) = espejote.jsonnetLibrary(jlName, params.namespace) + com.makeMergeable(params.jsonnetLibraries[jlName]);

// Managed Resources

local managedResource(mrName) =
  espejote.managedResource(namespacedName(mrName).name, namespacedName(mrName).namespace) + com.makeMergeable({
    spec+: {
      serviceAccountRef: {
        name: serviceAccountName(mrName),
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
      'app.kubernetes.io/name': serviceAccountName(mrName),
      'managedresource.espejote.io/name': namespacedName(mrName).name,
    },
    name: serviceAccountName(mrName),
    namespace: namespacedName(mrName).namespace,
  },
};

local role(path) = {
  local nsName = namespacedName(path),
  apiVersion: 'rbac.authorization.k8s.io/v1',
  kind: 'Role',
  metadata: {
    labels: {
      'app.kubernetes.io/name': nsName.name,
    },
    name: nsName.name,
    namespace: nsName.namespace,
  },
};

local clusterRole(path) =
  role(path) + {
    kind: 'ClusterRole',
    metadata+: {
      namespace:: null,
    },
  };

local roleBinding(roleNs, roleName, saNs, saName) = {
  local bindingName = std.join(':', std.prune([ 'espejote', 'supplemental', roleName, if saNs != roleNs then saNs, saName ])),
  apiVersion: 'rbac.authorization.k8s.io/v1',
  kind: 'RoleBinding',
  metadata: {
    labels: {
      'app.kubernetes.io/name': bindingName,
    },
    name: bindingName,
    [if roleNs != null then 'namespace']: roleNs,
  },
  roleRef: {
    apiGroup: 'rbac.authorization.k8s.io',
    kind: 'Role',
    name: roleName,
  },
  subjects: [
    {
      kind: 'ServiceAccount',
      name: saName,
      namespace: saNs,
    },
  ],
};

local clusterRoleBinding(roleName, saNs, saName) =
  roleBinding(null, roleName, saNs, saName) + {
    kind: 'ClusterRoleBinding',
  };

local roleBindingsForManagedResourceAndRoles = function(managedResourcePath, rolePaths)
  std.map(function(rp) roleBinding(
    namespacedName(rp).namespace,
    namespacedName(rp).name,
    namespacedName(managedResourcePath).namespace,
    serviceAccountName(managedResourcePath),
  ), rolePaths);

local clusterRoleBindingsForManagedResourceAndRoles = function(managedResourcePath, rolePaths)
  std.map(function(rp) clusterRoleBinding(
    namespacedName(rp).name,
    namespacedName(managedResourcePath).namespace,
    serviceAccountName(managedResourcePath),
  ), rolePaths);

local supplementalRoles = {
  ['43_supplemental_role_%(namespace)s_%(name)s' % namespacedName(path)]:
    local roles = std.get(params.managedResources[path], '_roles', {});
    com.generateResources(roles, role) +
    roleBindingsForManagedResourceAndRoles(path, std.objectFields(roles)) +
    roleBindingsForManagedResourceAndRoles(path, std.get(params.managedResources[path], '_roleBindings', []))
  for path in std.objectFields(params.managedResources)
};

local supplementalClusterRoles = {
  [if std.length(std.get(params.managedResources[path], '_clusterRoles', {})) > 0 then '44_supplemental_cluster_role_%(namespace)s_%(name)s' % namespacedName(path)]:
    local roles = std.get(params.managedResources[path], '_clusterRoles', {});
    com.generateResources(roles, clusterRole) +
    clusterRoleBindingsForManagedResourceAndRoles(path, std.objectFields(roles)) +
    clusterRoleBindingsForManagedResourceAndRoles(path, std.get(params.managedResources[path], '_clusterRoleBindings', []))
  for path in std.objectFields(params.managedResources)
};

// Define outputs below
{
  '00_namespace': namespace,
  '20_aggregated_cluster_role': aggregatedClusterRole,
  '30_alerts': alerts,
} + supplementalRoles + supplementalClusterRoles + {
  ['50_jl_%s' % namespacedName(name).name]: jsonnetLibrary(name)
  for name in std.objectFields(params.jsonnetLibraries)
} + {
  ['60_mr_%s_%s' % [ namespacedName(name).namespace, namespacedName(name).name ]]:
    local manifest = managedResource(name);
    [ serviceAccount(name) ] + espejote.readingRbacObjects(manifest)
  for name in std.objectFields(params.managedResources)
}
