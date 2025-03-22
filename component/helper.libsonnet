// main template for espejote
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();

// The hiera parameters for the component
local params = inv.parameters.espejote;


// Helpers: Names

local namespacedName(name, namespace='') = {
  local namespacedName = std.splitLimit(name, '/', 1),
  local ns = if namespace != '' then namespace else params.namespace,
  namespace: if std.length(namespacedName) > 1 then namespacedName[0] else ns,
  name: if std.length(namespacedName) > 1 then namespacedName[1] else namespacedName[0],
};

local hashedName(name, hidden=[]) =
  // Ensure the total length of the name is less than 63 characters
  // 63 - `espejote` - 2x `:` - hash length = 38
  local unhashed = std.substr(std.join(':', name), 0, 38);
  local toHash = std.join(':', name + hidden);
  local hashed = std.substr(std.md5(toHash), 0, 15);
  'espejote:%(unhashed)s:%(hashed)s' % [ unhashed, hashed ];

local serviceAccountName(name) = 'espejote:%s' % std.get(
  params.managedResources[name].spec,
  'serviceAccountRef',
  { name: namespacedName(name).name },
).name;

// Helpers: Extract triggers and context

local isNamespaceClusterScoped(namespace) = if namespace == params.namespace then true else false;
local isDifferentNamespaceThanMr(compare, mrName) = if compare != namespacedName(mrName).namespace then true else false;

local isContextOrTriggerClusterScoped(obj) =
  // The watchResource is of kind Namespace
  if obj.kind == 'Namespace' then true
  // The namespace of the watchResource is an empty string
  else if std.get(obj, 'namespace', null) == '' then true
  // Defaults to false
  else false;

// Helpers: Generate Roles and RoleBindings

local roleOrBindingName(mrName, clusterScoped, isBinding=false) =
  local roleOrBinding(clusterScoped) = if isBinding then
    if clusterScoped then 'clusterrolebinding' else 'rolebinding'
  else
    if clusterScoped then 'clusterrole' else 'role';
  if clusterScoped then
    hashedName([ namespacedName(mrName).namespace, namespacedName(mrName).name ], [ roleOrBinding(true) ])
  else
    hashedName([ namespacedName(mrName).name ], [ namespacedName(mrName).namespace, roleOrBinding(false) ]);

local roleNameContextOrTrigger(mrName, contextOrTriggerWord, contextOrTriggerNamespace, isBinding=false) =
  local roleOrBinding(clusterScoped) = if isBinding then
    if clusterScoped then 'clusterrolebinding' else 'rolebinding'
  else
    if clusterScoped then 'clusterrole' else 'role';
  if isNamespaceClusterScoped(contextOrTriggerNamespace) then
    hashedName([ namespacedName(mrName).namespace, namespacedName(mrName).name, contextOrTriggerWord ], [ roleOrBinding(true) ])
  else if isDifferentNamespaceThanMr(contextOrTriggerNamespace, mrName) then
    hashedName([ namespacedName(mrName).namespace, namespacedName(mrName).name, contextOrTriggerWord ], [ roleOrBinding(false) ])
  else
    hashedName([ namespacedName(mrName).name, contextOrTriggerWord ], [ contextOrTriggerNamespace, roleOrBinding(false) ]);

// Creates a list of triggers, sorted by the trigger's namespace
local listContextOrTrigger(mrName, isTrigger=false) =
  local contextOrTriggerWord = if isTrigger then 'triggers' else 'context';
  local getResource(item) = if isTrigger then
    std.get(item, 'watchResource', null)
  else
    std.get(item, 'resource', null);

  std.foldl(
    // Add element to the list of triggers based on the trigger's namespace
    function(obj, item) (
      local ns = if isContextOrTriggerClusterScoped(getResource(item)) then params.namespace
      else if std.get(getResource(item), 'namespace', null) != null then getResource(item).namespace
      else namespacedName(mrName).namespace;
      {
        [namespace]: if namespace == ns then obj[namespace] + [ item ] else obj[namespace]
        for namespace in std.objectFields(obj)
      }
    ),
    // Extract a list of triggers from the managed resource
    [
      item
      for item in std.get(params.managedResources[mrName].spec, contextOrTriggerWord, [])
      if getResource(item) != null
    ],
    // Generate an empty list of triggers for each namespace
    {
      [namespace]: []
      for namespace in std.uniq([
        if isContextOrTriggerClusterScoped(getResource(item)) then params.namespace
        else if std.get(getResource(item), 'namespace', null) != null then getResource(item).namespace
        else namespacedName(mrName).namespace
        for item in std.get(params.managedResources[mrName].spec, contextOrTriggerWord, [])
        if getResource(item) != null
      ])
    }
  );

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

{
  namespacedName: namespacedName,
  hashedName: hashedName,
  serviceAccountName: serviceAccountName,
  isNamespaceClusterScoped: isNamespaceClusterScoped,
  isDifferentNamespaceThanMr: isDifferentNamespaceThanMr,
  isContextOrTriggerClusterScoped: isContextOrTriggerClusterScoped,
  roleOrBindingName: roleOrBindingName,
  roleNameContextOrTrigger: roleNameContextOrTrigger,
  listContextOrTrigger: listContextOrTrigger,
  processRole: processRole,
  processRoleBinding: processRoleBinding,
}
