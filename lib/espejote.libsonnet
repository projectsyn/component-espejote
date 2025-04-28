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
  * \brief Internal functions to help creating reading RBAC objects.
  */
local roles = {
  isNamespaceClusterScoped: function(namespace) namespace == inv.parameters.espejote.namespace,
  isDifferentNamespaceThanMr: function(compare, mrNamespace) compare != mrNamespace,

  // List context or trigger from a managed resource
  listContextOrTrigger: function(mrManifest, isTrigger=false) (
    local contextOrTriggerWord = if isTrigger then 'triggers' else 'context';

    local getResource(item) = if isTrigger then
      std.get(item, 'watchResource', null)
    else
      std.get(item, 'resource', null);

    local isContextOrTriggerClusterScoped(obj) =
      // Namespaces are a cluster scoped resource, namespaced resources can be read from the whole cluster by setting the namespace to ''.
      // Default for espejote is to scope the triggers and contexts to the namespace of the managed resource.
      obj.kind == 'Namespace' || std.get(obj, 'namespace', null) == '';

    local _listContextOrTrigger = [
      item
      for item in std.get(mrManifest.spec, contextOrTriggerWord, [])
      if getResource(item) != null
    ];

    std.foldl(
      // Add element to the list of triggers based on the trigger's namespace
      function(obj, item) (
        local ns = if isContextOrTriggerClusterScoped(getResource(item)) then inv.parameters.espejote.namespace
        else if std.get(getResource(item), 'namespace', null) != null then getResource(item).namespace
        else mrManifest.metadata.namespace;
        {
          [namespace]: if namespace == ns then obj[namespace] + [ item ] else obj[namespace]
          for namespace in std.objectFields(obj)
        }
      ),
      // List of triggers from the managed resource
      _listContextOrTrigger,
      // Generate an empty list of triggers for each namespace
      {
        [namespace]: []
        for namespace in std.uniq([
          if isContextOrTriggerClusterScoped(getResource(item)) then inv.parameters.espejote.namespace
          else if std.get(getResource(item), 'namespace', null) != null then getResource(item).namespace
          else mrManifest.metadata.namespace
          for item in _listContextOrTrigger
        ])
      }
    )
  ),

  // Generate role names
  roleNameContextOrTrigger: function(mrManifest, contextOrTriggerWord, contextOrTriggerNamespace, isBinding=false) (
    local hashedName(name, hidden=[]) =
      // Ensure the total length of the name is less than 63 characters
      // 63 - `espejote` - 2x `:` - hash length = 38
      local unhashed = std.substr(std.join(':', name), 0, 38);
      local toHash = std.join(':', name + hidden);
      local hashed = std.substr(std.md5(toHash), 0, 15);
      'espejote:%(unhashed)s:%(hashed)s' % [ unhashed, hashed ];

    local roleOrBinding(clusterScoped) = if isBinding then
      if clusterScoped then 'clusterrolebinding' else 'rolebinding'
    else
      if clusterScoped then 'clusterrole' else 'role';

    if roles.isNamespaceClusterScoped(contextOrTriggerNamespace) then
      hashedName([ mrManifest.metadata.namespace, mrManifest.metadata.name, contextOrTriggerWord ], [ roleOrBinding(true) ])
    else if roles.isDifferentNamespaceThanMr(contextOrTriggerNamespace, mrManifest.metadata.namespace) then
      hashedName([ mrManifest.metadata.namespace, mrManifest.metadata.name, contextOrTriggerWord ], [ roleOrBinding(false) ])
    else
      hashedName([ mrManifest.metadata.name, contextOrTriggerWord ], [ contextOrTriggerNamespace, roleOrBinding(false) ])
  ),

  // Generate roles
  processRole: function(r) r {
    local extraRules = std.objectValues(
      com.getValueOrDefault(r, 'rules_', {})
    ),
    rules_:: null,
    rules+: [ {
      apiGroups: com.renderArray(rule.apiGroups),
      resources: com.renderArray(rule.resources),
      verbs: com.renderArray(rule.verbs),
    } for rule in extraRules ],
  },

  generateRolesContextOrTrigger: function(mrManifest, contextOrTriggerWord) (
    local isTrigger = contextOrTriggerWord == 'trigger';
    local contextOrTriggerList = roles.listContextOrTrigger(mrManifest, isTrigger);
    local getResource(item) = if contextOrTriggerWord == 'context' then
      std.get(item, 'resource')
    else
      std.get(item, 'watchResource');

    [
      local clusterScoped = roles.isNamespaceClusterScoped(contextOrTriggerNamespace);
      local roleName = roles.roleNameContextOrTrigger(mrManifest, contextOrTriggerWord, contextOrTriggerNamespace);
      roles.processRole({
        apiVersion: 'rbac.authorization.k8s.io/v1',
        kind: if clusterScoped then 'ClusterRole' else 'Role',
        metadata: {
          labels: {
            'app.kubernetes.io/name': roleName,
            'managedresource.espejote.io/name': mrManifest.metadata.name,
            [if clusterScoped || roles.isDifferentNamespaceThanMr(contextOrTriggerNamespace, mrManifest.metadata.namespace) then 'managedresource.espejote.io/namespace']: mrManifest.metadata.namespace,
          },
          name: roleName,
          [if !clusterScoped then 'namespace']: contextOrTriggerNamespace,
        },
        rules_: {
          [item.name]: {
            apiGroups: [ getResource(item).apiVersion ],
            resources: [ std.asciiLower(getResource(item).kind) ],
            verbs: [ 'get', 'list', 'watch' ],
          }
          for item in contextOrTriggerList[contextOrTriggerNamespace]
        },
      })
      for contextOrTriggerNamespace in std.objectFields(contextOrTriggerList)
    ]
  ),

  // Generate role bindings
  processRoleBinding: function(rb) rb {
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
  },

  generateBindingsContextOrTrigger: function(mrManifest, contextOrTriggerWord) (
    local isTrigger = contextOrTriggerWord == 'trigger';
    local contextOrTriggerList = roles.listContextOrTrigger(mrManifest, isTrigger);

    [
      local clusterScoped = roles.isNamespaceClusterScoped(contextOrTriggerNamespace);
      local roleName = roles.roleNameContextOrTrigger(mrManifest, contextOrTriggerWord, contextOrTriggerNamespace);
      local roleBindingName = roles.roleNameContextOrTrigger(mrManifest, contextOrTriggerWord, contextOrTriggerNamespace, true);
      roles.processRoleBinding({
        apiVersion: 'rbac.authorization.k8s.io/v1',
        kind: if clusterScoped then 'ClusterRoleBinding' else 'RoleBinding',
        metadata: {
          labels: {
            'app.kubernetes.io/name': roleBindingName,
            'managedresource.espejote.io/name': mrManifest.metadata.name,
            [if clusterScoped || roles.isDifferentNamespaceThanMr(contextOrTriggerNamespace, mrManifest.metadata.namespace) then 'managedresource.espejote.io/namespace']: mrManifest.metadata.namespace,
          },
          name: roleBindingName,
          [if !clusterScoped then 'namespace']: contextOrTriggerNamespace,
        },
        [if clusterScoped then 'clusterRole_' else 'role_']: roleName,
        subjects: [ {
          kind: 'ServiceAccount',
          name: mrManifest.spec.serviceAccountRef.name,
          namespace: mrManifest.metadata.namespace,
        } ],
      })
      for contextOrTriggerNamespace in std.objectFields(contextOrTriggerList)
    ]
  ),
};


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

/**
  * \brief Helper to generate roles and role bindings for reading referenced resources.
  *
  * \arg The ManagedResource.
  * \return A list of roles and role bindings.
  */
local readingRbacObjects(manifest) =
  roles.generateRolesContextOrTrigger(manifest, 'context')
  + roles.generateBindingsContextOrTrigger(manifest, 'context')
  + roles.generateRolesContextOrTrigger(manifest, 'trigger')
  + roles.generateBindingsContextOrTrigger(manifest, 'trigger');


{
  admission: admission,
  jsonnetLibrary: jsonnetLibrary,
  managedResource: managedResource,
  readingRbacObjects: readingRbacObjects,
}
