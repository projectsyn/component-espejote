// main template for espejote
local helper = import 'helper.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local espejote = import 'lib/espejote.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();

// The hiera parameters for the component
local params = inv.parameters.espejote;

// Helpers: Generate Roles and RoleBindings

local roleOrBindingName(mrName, clusterScoped, isBinding=false) =
  local roleOrBinding(clusterScoped) = if isBinding then
    if clusterScoped then 'clusterrolebinding' else 'rolebinding'
  else
    if clusterScoped then 'clusterrole' else 'role';
  if clusterScoped then
    helper.hashedName([ helper.namespacedName(mrName).namespace, helper.namespacedName(mrName).name ], [ roleOrBinding(true) ])
  else
    helper.hashedName([ helper.namespacedName(mrName).name ], [ helper.namespacedName(mrName).namespace, roleOrBinding(false) ]);

local generateRole(mrName, rules, clusterScoped=false) =
  local roleName = roleOrBindingName(mrName, clusterScoped);

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
  local roleBindingName = roleOrBindingName(mrName, clusterScoped, true);

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

{
  generateRole: generateRole,
  generateBinding: generateBinding,
}
