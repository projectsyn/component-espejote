local esp = import 'lib/espejote.libsonnet';

{
  image_config: esp.clusterScopedObject(
    'openshift-config',
    {
      apiVersion: 'config.openshift.io/v1',
      kind: 'Image',
      metadata: {
        name: 'cluster',
      },
      spec: {
        allowedRegistriesForImport: [ {
          domainName: 'ghcr.io',
        } ],
      },
    }
  ),
  image_config_override: esp.clusterScopedObject(
    'openshift-config',
    {
      apiVersion: 'config.openshift.io/v1',
      kind: 'Image',
      metadata: {
        name: 'cluster',
      },
      spec: {
        allowedRegistriesForImport: [ {
          domainName: 'ghcr.io',
        } ],
      },
    },
    resource='images',
    mgr_name='image-config-openshift-io-mgr'
  ),
}
