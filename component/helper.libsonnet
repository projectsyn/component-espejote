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

local serviceAccountName(name) =
  if std.get(params.managedResources[name].spec, 'serviceAccountRef', null) != null then
    params.managedResources[name].spec.serviceAccountRef.name
  else
    'espejote-%s' % namespacedName(name).name;

// Helpers: Extract triggers and context

local isNamespaceClusterScoped(namespace) = namespace == params.namespace;
local isDifferentNamespaceThanMr(compare, mrName) = compare != namespacedName(mrName).namespace;

local isContextOrTriggerClusterScoped(obj) =
  // Namespaces are a cluster scoped resource, namespaced resources can be read from the whole cluster by setting the namespace to ''.
  // Default for espejote is to scope the triggers and contexts to the namespace of the managed resource.
  obj.kind == 'Namespace' || std.get(obj, 'namespace', null) == '';

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

{
  namespacedName: namespacedName,
  hashedName: hashedName,
  serviceAccountName: serviceAccountName,
  isNamespaceClusterScoped: isNamespaceClusterScoped,
  isDifferentNamespaceThanMr: isDifferentNamespaceThanMr,
  isContextOrTriggerClusterScoped: isContextOrTriggerClusterScoped,
  processRole: processRole,
  processRoleBinding: processRoleBinding,
}
