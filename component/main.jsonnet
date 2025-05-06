// main template for espejote
local com = import 'lib/commodore.libjsonnet';
local espejote = import 'lib/espejote.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
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
  espejote.serviceAccountNameFromManagedResource(
    params.managedResources[name].spec,
    'espejote-%s' % namespacedName(name).name
  );

// Jsonnet Libraries

local jsonnetLibrary(jlPath) =
  local nsName = namespacedName(jlPath);
  espejote.jsonnetLibrary(nsName.name, nsName.namespace) + com.makeMergeable(params.jsonnetLibraries[jlPath]);

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

local role(prefix, defaultNamespace) =
  function(path) {
    local nsName = namespacedName(path, namespace=defaultNamespace),
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'Role',
    metadata: {
      labels: {
        'app.kubernetes.io/name': prefix + nsName.name,
      },
      name: prefix + nsName.name,
      namespace: nsName.namespace,
    },
  };

local clusterRole(prefix) =
  function(path)
    role(prefix, null)(path) + {
      kind: 'ClusterRole',
      metadata+: {
        namespace:: null,
      },
    };

local roleBinding(roleNamePrefix) =
  function(roleNs, roleName, saNs, saName) {
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
      name: roleNamePrefix + roleName,
    },
    subjects: [
      {
        kind: 'ServiceAccount',
        name: saName,
        namespace: saNs,
      },
    ],
  };

local clusterRoleBinding(roleNamePrefix) =
  function(roleName, saNs, saName)
    roleBinding(roleNamePrefix)(null, roleName, saNs, saName) + {
      kind: 'ClusterRoleBinding',
    };

local roleBindingsForManagedResourceAndRoles(roleNamePrefix) =
  function(managedResourcePath, rolePaths)
    local mrNs = namespacedName(managedResourcePath).namespace;
    std.map(function(rp)
      local roleNsName = namespacedName(rp, namespace=mrNs);
      roleBinding(roleNamePrefix)(
        roleNsName.namespace,
        roleNsName.name,
        mrNs,
        serviceAccountName(managedResourcePath),
      ), rolePaths);

local clusterRoleBindingsForManagedResourceAndRoles(roleNamePrefix) =
  function(managedResourcePath, rolePaths)
    std.map(function(rp) clusterRoleBinding(roleNamePrefix)(
      namespacedName(rp).name,
      namespacedName(managedResourcePath).namespace,
      serviceAccountName(managedResourcePath),
    ), rolePaths);

local supplementalRoles = std.prune({
  ['43_supplemental_role_%(namespace)s_%(name)s' % namespacedName(path)]:
    local roles = std.get(params.managedResources[path], '_roles', {});
    local mrNsName = namespacedName(path);
    local roleNamePrefix = std.join(':', [ 'espejote', 'supplemental', mrNsName.namespace, mrNsName.name, '' ]);
    com.generateResources(roles, role(roleNamePrefix, mrNsName.namespace)) +
    roleBindingsForManagedResourceAndRoles(roleNamePrefix)(path, std.objectFields(roles)) +
    roleBindingsForManagedResourceAndRoles(roleNamePrefix)(path, std.get(params.managedResources[path], '_roleBindings', []))
  for path in std.objectFields(params.managedResources)
});

local supplementalClusterRoles = std.prune({
  [if std.length(std.get(params.managedResources[path], '_clusterRoles', {})) > 0 then '44_supplemental_cluster_role_%(namespace)s_%(name)s' % namespacedName(path)]:
    local roles = std.get(params.managedResources[path], '_clusterRoles', {});
    local mrNsName = namespacedName(path);
    local roleNamePrefix = std.join(':', [ 'espejote', 'supplemental', mrNsName.namespace, mrNsName.name, '' ]);
    com.generateResources(roles, clusterRole(roleNamePrefix)) +
    clusterRoleBindingsForManagedResourceAndRoles(roleNamePrefix)(path, std.objectFields(roles)) +
    clusterRoleBindingsForManagedResourceAndRoles(roleNamePrefix)(path, std.get(params.managedResources[path], '_clusterRoleBindings', []))
  for path in std.objectFields(params.managedResources)
});

// Define outputs below
{
  '00_namespace': namespace,
  '20_aggregated_cluster_role': aggregatedClusterRole,
  '30_alerts': alerts,
} + supplementalRoles + supplementalClusterRoles + {
  ['50_jl_%(namespace)s_%(name)s' % namespacedName(name)]: jsonnetLibrary(name)
  for name in std.objectFields(params.jsonnetLibraries)
} + {
  ['60_mr_%s_%s' % [ namespacedName(name).namespace, namespacedName(name).name ]]:
    local manifest = managedResource(name);
    [ serviceAccount(name) ] + espejote.createContextRBAC(manifest)
  for name in std.objectFields(params.managedResources)
}
