/**
 * \file espejote.libsonnet
 * \brief Helpers to create Espejote CRs.
 *        API reference: https://github.com/vshn/espejote/blob/main/docs/api.adoc
 */

local helper = import 'component/helper.libsonnet';
local roles = import 'component/roles.libsonnet';
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

{
  admission: admission,
  jsonnetLibrary: jsonnetLibrary,
  managedResource: managedResource,
}
