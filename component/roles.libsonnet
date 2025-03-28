// main template for espejote
local helper = import 'helper.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local espejote = import 'lib/espejote.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();

// The hiera parameters for the component
local params = inv.parameters.espejote;

// Helpers: Generate Roles and RoleBindings

local generateRole(mrName, rules, clusterScoped=false) =
  local roleName = helper.roleOrBindingName(mrName, clusterScoped);

  helper.processRole({
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: if clusterScoped then 'ClusterRole' else 'Role',
    metadata: {
      labels: {
        'app.kubernetes.io/name': roleName,
        'managedresource.espejote.io/name': helper.namespacedName(mrName).name,
        [if clusterScoped then 'managedresource.espejote.io/namespace']: helper.namespacedName(mrName).namespace,
      },
      name: roleName,
      [if !clusterScoped then 'namespace']: helper.namespacedName(mrName).namespace,
    },
    rules_: rules,
  });

local generateBinding(mrName, roleName, clusterScoped=false) =
  local roleBindingName = helper.roleOrBindingName(mrName, clusterScoped, true);

  helper.processRoleBinding({
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: if clusterScoped then 'ClusterRoleBinding' else 'RoleBinding',
    metadata: {
      labels: {
        'app.kubernetes.io/name': roleBindingName,
        'managedresource.espejote.io/name': helper.namespacedName(mrName).name,
        [if clusterScoped then 'managedresource.espejote.io/namespace']: helper.namespacedName(mrName).namespace,
      },
      name: roleBindingName,
      [if !clusterScoped then 'namespace']: helper.namespacedName(mrName).namespace,
    },
    [if clusterScoped then 'clusterRole_' else 'role_']: roleName,
    subjects: [ {
      kind: 'ServiceAccount',
      name: helper.serviceAccountName(mrName),
      namespace: helper.namespacedName(mrName).namespace,
    } ],
  });

local generateRolesContextOrTrigger(mrName, contextOrTriggerWord) =
  local isTrigger = if contextOrTriggerWord == 'trigger' then true else false;
  local contextOrTriggerList = helper.listContextOrTrigger(mrName, isTrigger);
  local getResource(item) = if contextOrTriggerWord == 'context' then
    std.get(item, 'resource')
  else
    std.get(item, 'watchResource');

  [
    local clusterScoped = helper.isNamespaceClusterScoped(contextOrTriggerNamespace);
    local roleName = helper.roleNameContextOrTrigger(mrName, contextOrTriggerWord, contextOrTriggerNamespace);
    helper.processRole({
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: if clusterScoped then 'ClusterRole' else 'Role',
      metadata: {
        labels: {
          'app.kubernetes.io/name': roleName,
          'managedresource.espejote.io/name': helper.namespacedName(mrName).name,
          [if clusterScoped || helper.isDifferentNamespaceThanMr(contextOrTriggerNamespace, mrName) then 'managedresource.espejote.io/namespace']: helper.namespacedName(mrName).namespace,
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
  ];

local generateBindingsContextOrTrigger(mrName, contextOrTriggerWord) =
  local isTrigger = if contextOrTriggerWord == 'trigger' then true else false;
  local contextOrTriggerList = helper.listContextOrTrigger(mrName, isTrigger);

  [
    local clusterScoped = helper.isNamespaceClusterScoped(contextOrTriggerNamespace);
    local roleName = helper.roleNameContextOrTrigger(mrName, contextOrTriggerWord, contextOrTriggerNamespace);
    local roleBindingName = helper.roleNameContextOrTrigger(mrName, contextOrTriggerWord, contextOrTriggerNamespace, true);
    helper.processRoleBinding({
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: if clusterScoped then 'ClusterRoleBinding' else 'RoleBinding',
      metadata: {
        labels: {
          'app.kubernetes.io/name': roleBindingName,
          'managedresource.espejote.io/name': helper.namespacedName(mrName).name,
          [if clusterScoped || helper.isDifferentNamespaceThanMr(contextOrTriggerNamespace, mrName) then 'managedresource.espejote.io/namespace']: helper.namespacedName(mrName).namespace,
        },
        name: roleBindingName,
        [if !clusterScoped then 'namespace']: contextOrTriggerNamespace,
      },
      [if clusterScoped then 'clusterRole_' else 'role_']: roleName,
      subjects: [ {
        kind: 'ServiceAccount',
        name: helper.serviceAccountName(mrName),
        namespace: helper.namespacedName(mrName).namespace,
      } ],
    })
    for contextOrTriggerNamespace in std.objectFields(contextOrTriggerList)
  ];

{
  generateRole: generateRole,
  generateRolesContextOrTrigger: generateRolesContextOrTrigger,
  generateBinding: generateBinding,
  generateBindingsContextOrTrigger: generateBindingsContextOrTrigger,
}
