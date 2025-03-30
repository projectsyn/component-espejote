// main template for espejote
local helper = import 'helper.libsonnet';
local espejote = import 'lib/espejote.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();

// The hiera parameters for the component
local params = inv.parameters.espejote;

// Helper: Context and Trigger

// Creates a list of triggers, sorted by the trigger's namespace
local listContextOrTrigger(mrManifest, isTrigger=false) =
  local contextOrTriggerWord = if isTrigger then 'triggers' else 'context';
  local getResource(item) = if isTrigger then
    std.get(item, 'watchResource', null)
  else
    std.get(item, 'resource', null);

  local _listContextOrTrigger = [
    item
    for item in std.get(mrManifest.spec, contextOrTriggerWord, [])
    if getResource(item) != null
  ];

  std.foldl(
    // Add element to the list of triggers based on the trigger's namespace
    function(obj, item) (
      local ns = if helper.isContextOrTriggerClusterScoped(getResource(item)) then params.namespace
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
        if helper.isContextOrTriggerClusterScoped(getResource(item)) then params.namespace
        else if std.get(getResource(item), 'namespace', null) != null then getResource(item).namespace
        else mrManifest.metadata.namespace
        for item in _listContextOrTrigger
      ])
    }
  );

// Helpers: Generate Roles and RoleBindings

local roleNameContextOrTrigger(mrManifest, contextOrTriggerWord, contextOrTriggerNamespace, isBinding=false) =
  local compoundName = '%(namespace)s/%(name)s' % mrManifest.metadata;
  local roleOrBinding(clusterScoped) = if isBinding then
    if clusterScoped then 'clusterrolebinding' else 'rolebinding'
  else
    if clusterScoped then 'clusterrole' else 'role';
  if helper.isNamespaceClusterScoped(contextOrTriggerNamespace) then
    helper.hashedName([ mrManifest.metadata.namespace, mrManifest.metadata.name, contextOrTriggerWord ], [ roleOrBinding(true) ])
  else if helper.isDifferentNamespaceThanMr(contextOrTriggerNamespace, compoundName) then
    helper.hashedName([ mrManifest.metadata.namespace, mrManifest.metadata.name, contextOrTriggerWord ], [ roleOrBinding(false) ])
  else
    helper.hashedName([ mrManifest.metadata.name, contextOrTriggerWord ], [ contextOrTriggerNamespace, roleOrBinding(false) ]);

local generateRolesContextOrTrigger(mrManifest, contextOrTriggerWord) =
  local compoundName = '%(namespace)s/%(name)s' % mrManifest.metadata;
  local isTrigger = if contextOrTriggerWord == 'trigger' then true else false;
  local contextOrTriggerList = listContextOrTrigger(mrManifest, isTrigger);
  local getResource(item) = if contextOrTriggerWord == 'context' then
    std.get(item, 'resource')
  else
    std.get(item, 'watchResource');

  [
    local clusterScoped = helper.isNamespaceClusterScoped(contextOrTriggerNamespace);
    local roleName = roleNameContextOrTrigger(mrManifest, contextOrTriggerWord, contextOrTriggerNamespace);
    helper.processRole({
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: if clusterScoped then 'ClusterRole' else 'Role',
      metadata: {
        labels: {
          'app.kubernetes.io/name': roleName,
          'managedresource.espejote.io/name': mrManifest.metadata.name,
          [if clusterScoped || helper.isDifferentNamespaceThanMr(contextOrTriggerNamespace, compoundName) then 'managedresource.espejote.io/namespace']: mrManifest.metadata.namespace,
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

local generateBindingsContextOrTrigger(mrManifest, contextOrTriggerWord) =
  local compoundName = '%s/%s' % [ mrManifest.metadata.namespace, mrManifest.metadata.name ];
  local isTrigger = if contextOrTriggerWord == 'trigger' then true else false;
  local contextOrTriggerList = listContextOrTrigger(mrManifest, isTrigger);

  [
    local clusterScoped = helper.isNamespaceClusterScoped(contextOrTriggerNamespace);
    local roleName = roleNameContextOrTrigger(mrManifest, contextOrTriggerWord, contextOrTriggerNamespace);
    local roleBindingName = roleNameContextOrTrigger(mrManifest, contextOrTriggerWord, contextOrTriggerNamespace, true);
    helper.processRoleBinding({
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: if clusterScoped then 'ClusterRoleBinding' else 'RoleBinding',
      metadata: {
        labels: {
          'app.kubernetes.io/name': roleBindingName,
          'managedresource.espejote.io/name': mrManifest.metadata.name,
          [if clusterScoped || helper.isDifferentNamespaceThanMr(contextOrTriggerNamespace, compoundName) then 'managedresource.espejote.io/namespace']: mrManifest.metadata.namespace,
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
  ];

{
  generateRolesContextOrTrigger: generateRolesContextOrTrigger,
  generateBindingsContextOrTrigger: generateBindingsContextOrTrigger,
}
