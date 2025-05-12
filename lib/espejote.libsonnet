/**
 * \file espejote.libsonnet
 * \brief Helpers to create Espejote CRs.
 *        API reference: https://github.com/vshn/espejote/blob/main/docs/api.adoc
 */

local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local groupVersion = 'espejote.io/v1alpha1';

/**
  * \brief Helper to create JsonnetLibrary objects.
  *
  * \arg The name of the JsonnetLibrary.
  * \arg The namespace of the ManagedResource.
  * \return A JsonnetLibrary object.
  */
local jsonnetLibrary(name, namespace) = {
  apiVersion: groupVersion,
  kind: 'JsonnetLibrary',
  metadata: {
    labels: {
      'app.kubernetes.io/name': name,
    },
    name: name,
    namespace: namespace,
  },
};

/**
  * \brief Helper to create Admission objects.
  *
  * \arg The name of the Admission.
  * \arg The namespace of the ManagedResource.
  * \return A Admission object.
  */
local admission(name, namespace) = {
  apiVersion: groupVersion,
  kind: 'Admission',
  metadata: {
    labels: {
      'app.kubernetes.io/name': name,
    },
    name: name,
    namespace: namespace,
  },
};

/**
  * \brief Helper to create ManagedResource objects.
  *
  * \arg The name of the ManagedResource.
  * \arg The namespace of the ManagedResource.
  * \return A ManagedResource object.
  */
local managedResource(name, namespace) = {
  apiVersion: groupVersion,
  kind: 'ManagedResource',
  metadata: {
    labels: {
      'app.kubernetes.io/name': name,
    },
    name: name,
    namespace: namespace,
  },
};

// Guesses the resource from the resource kind.
// Inspired by https://github.com/kubernetes/apimachinery/blob/954960919938450fb6d06065f4bf92855dda73fd/pkg/api/meta/restmapper.go#L126
local guessResourceFromKind(kind) =
  local singular = std.asciiLower(kind);
  local irregular = {
    endpoints: 'endpoints',
  };

  if std.objectHas(irregular, singular) then
    irregular[singular]
  else if std.endsWith(singular, 's') || std.endsWith(singular, 'ch') || std.endsWith(singular, 'x') then
    singular + 'es'
  else if std.endsWith(singular, 'y') then
    std.substr(singular, 0, std.length(singular) - 1) + 'ies'
  else
    singular + 's';


local generateRolesForManagedResource(manifest) =
  local manifestMeta = std.get(manifest, 'metadata', {});
  assert std.objectHas(manifestMeta, 'name') : 'name is required';
  assert std.objectHas(manifestMeta, 'namespace') : 'namespace is required';
  local manifestSpec = std.get(manifest, 'spec', {});

  local clusterScoped(resource) =
    if std.objectHas(resource, '_namespaced') then
      !std.get(resource, '_namespaced')
    else
      resource.kind == 'Namespace' || std.startsWith(resource.kind, 'Cluster') || std.get(resource, 'namespace') == '';

  local groupFromAPIVersion(apiVersion) =
    local parts = std.split(apiVersion, '/');
    if std.length(parts) == 1 then
      ''
    else
      parts[0];

  local roleFromResource(suffixes, resource) = {
    local resourceNs = std.get(resource, 'namespace', manifestMeta.namespace),
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: if clusterScoped(resource) then 'ClusterRole' else 'Role',
    metadata: {
      [if !clusterScoped(resource) then 'namespace']: resourceNs,
      name: std.join(':', std.prune([
        'espejote',
        'managedresource',
        if clusterScoped(resource) || manifestMeta.namespace != resourceNs then manifestMeta.namespace,
        manifestMeta.name,
      ] + suffixes)),
    },
    rules: [
      {
        apiGroups: [ groupFromAPIVersion(std.get(resource, 'apiVersion', '')) ],
        resources: [
          std.get(resource, '_resource', guessResourceFromKind(resource.kind)),
        ],
        verbs: [ 'get', 'list', 'watch' ],
      },
    ],
  };

  [
    roleFromResource([ 'triggers', item.name ], item.watchResource)
    for item in std.get(manifestSpec, 'triggers', [])
    if std.get(std.get(item, 'watchResource', {}), 'kind', '') != ''
  ] + [
    roleFromResource([ 'context', item.name ], item.resource)
    for item in std.get(manifestSpec, 'context', [])
    if std.get(std.get(item, 'resource', {}), 'kind', '') != ''
  ];

local bindRoles(saNamespace, saName, roles) = [
  {
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: role.kind + 'Binding',
    metadata: {
      name: role.metadata.name,
      [if std.objectHas(role.metadata, 'namespace') then 'namespace']: role.metadata.namespace,
    },
    roleRef: {
      apiGroup: 'rbac.authorization.k8s.io',
      kind: role.kind,
      name: role.metadata.name,
    },
    subjects: [
      {
        kind: 'ServiceAccount',
        name: saName,
        namespace: saNamespace,
      },
    ],
  }
  for role in roles
];

local hideInternalKeys(manifest) = manifest {
  spec+: {
    triggers: [
      if std.objectHas(item, 'watchResource') then
        item {
          watchResource: item.watchResource {
            _namespaced:: item.watchResource._namespaced,
            _resource:: item.watchResource._resource,
          },
        }
      else
        item
      for item in std.get(manifest.spec, 'triggers', [])
    ],
    context: [
      if std.objectHas(item, 'resource') then
        item {
          resource: item.resource {
            _namespaced:: item.resource._namespaced,
            _resource:: item.resource._resource,
          },
        }
      else
        item
      for item in std.get(manifest.spec, 'context', [])
    ],
  },
};

/**
  * \brief Returns the name of the ServiceAccount a ManagedResource uses or `default`.
  *
  * \arg The ManagedResource manifest.
  * \arg The default ServiceAccount name to return if not found. Defaults to `default`.
  * \return The name of the ServiceAccount as a string.
  */
local serviceAccountNameFromManagedResource(manifest, default='default') =
  std.get(std.get(std.get(manifest, 'spec', {}), 'serviceAccountRef', {}), 'name', default);

/**
  * \brief Automatically generates RBAC roles and bindings for a ManagedResources context and trigger sections.
  *
  * This function generates RBAC roles and bindings for the context and trigger sections of a ManagedResource.
  * A role or cluster role, with binding, is created for each resource section in the context and trigger sections.
  * The function tries to guess the resource name and the scope of the resource.
  * It is possible to override the guessed resource name and scope by adding the `_resource: 'irregular'` and `_namespaced: false` keys to the resource.
  * Those keys are removed from the returned ManagedResource manifest.
  *
  *   spec:
  *     context:
  *       - name: configmaps
  *         watchResource:
  *           apiVersion: v1
  *           kind: ConfigMap
  *       - name: namespaces
  *         watchResource:
  *           apiVersion: v1
  *           kind: Namespace
  *       - name: pods
  *         watchResource:
  *           apiVersion: v1
  *           kind: Pod
  *           namespace: ''
  *       - name: clusterversions
  *         watchResource:
  *           apiVersion: v1
  *           kind: ClusterVersion
  *     triggers:
  *       - name: weird-resource
  *         watchResource:
  *           _resource: sheep
  *           _namespaced: false
  *           apiVersion: cattle.farmersdelight.io/v1
  *           kind: Sheep
  *
  * creates a role for the ConfigMaps and a ClusterRole for the Sheep, Namespaces, Pods, and ClusterVersions.
  *
  * \arg The ManagedResource manifest.
  * \arg The default ServiceAccount name to return if not found. Defaults to `default`.
  * \return An list of manifests with the cleaned Managed Resource in the first position and the RBAC roles and bindings in the rest.
  */
local createContextRBAC(manifest) =
  local roles = generateRolesForManagedResource(manifest);
  [ hideInternalKeys(manifest) ] + roles + bindRoles(
    manifest.metadata.namespace,
    serviceAccountNameFromManagedResource(manifest),
    roles
  );

/**
 * \brief Generate a managed resource and associated service account and RBAC
 *        for managing a partial cluster-scoped object.
 *
 * This function generates a service account, RBAC and a a managed resource to
 * apply the partial `obj`. The function expects that the provided `obj` has
 * fields `apiVersion`, `kind` and `metadata.name`. Additionally the function
 * expects those fields to uniquely identify a cluster-scoped target object.
 *
 * The function tries to guess the resource name for RBAC from the provided
 * `obj.kind`. The resource name can be provided explicitly via parameter
 * `resource` if the guessed resource is incorrect.
 *
 * \mr_namespace the namespace for the managed resource (and service account)
 * \obj the partial manifest to apply. The function expects that this object
 *      has fields `apiVersion`, `kind` and `metadata.name` to identify a
 *      target resource in the cluster.
 * \resource overrides the guessed resource from the provided `obj.kind`
 * \mgr_name overrides the generated manager name (for the service account
 *           etc.). When this is given, it's the caller's responsibility to
 *           ensure that there are no name conflicts in the `mr_namespace`.
 *
 * \return A list containing the manifests required to apply the partial
 *         config to the target object.
 */
local clusterScopedObject(mr_namespace, obj, resource=null, mgr_name=null) =
  local apiVersion = obj.apiVersion;
  local kind = obj.kind;
  local name = obj.metadata.name;

  local apigrp =
    local api = std.split(apiVersion, '/');
    if std.length(api) > 1 then api[0] else '';
  local res = if resource != null then resource else guessResourceFromKind(kind);
  local mgrName = if mgr_name != null then
    mgr_name
  else
    '%s-%s-%s-manager' % [ std.strReplace(apigrp, '.', '-'), res, name ];
  local sa =
    {
      apiVersion: 'v1',
      kind: 'ServiceAccount',
      metadata+: {
        name: mgrName,
        namespace: mr_namespace,
      },
    };
  local clusterrole = {
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'ClusterRole',
    metadata: {
      name: '%s:%s' % [ mr_namespace, mgrName ],
    },
    rules: [
      {
        apiGroups: [ apigrp ],
        resources: [ res ],
        resourceNames: [ name ],
        verbs: [ '*' ],
      },
    ],
  };
  [ sa, clusterrole ] +
  bindRoles(mr_namespace, sa.metadata.name, [ clusterrole ]) +
  [
    managedResource(mgrName, mr_namespace) {
      spec: {
        applyOptions: { force: true },
        serviceAccountRef: { name: sa.metadata.name },
        triggers: [
          {
            name: 'target',
            watchResource: {
              apiVersion: apiVersion,
              kind: kind,
              name: name,
            },
          },
        ],
        template: std.manifestJson(obj),
      },
    },
  ];


{
  admission: admission,
  jsonnetLibrary: jsonnetLibrary,
  managedResource: managedResource,

  serviceAccountNameFromManagedResource: serviceAccountNameFromManagedResource,
  createContextRBAC: createContextRBAC,
  clusterScopedObject: clusterScopedObject,
}
