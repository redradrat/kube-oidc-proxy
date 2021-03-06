local kube = import '../vendor/kube-prod-runtime/lib/kube.libsonnet';
local utils = import '../vendor/kube-prod-runtime/lib/utils.libsonnet';

local contour_clusterrole = import 'contour-clusterrole.json';
local contour_crds = import 'contour-crds.json';

local CONTOUR_IMAGE = 'gcr.io/heptio-images/contour:v0.10.0';
local ENVOY_IMAGE = 'docker.io/envoyproxy/envoy-alpine:v1.9.0';

local apiGroup = 'contour.heptio.com';
local apiVersion = 'v1beta1';

{
  p:: '',
  app:: 'contour',
  cloud:: '',

  name:: $.p + $.app,

  namespace:: 'contour',

  labels:: {
    metadata+: {
      labels+: {
        app: $.app,
      },
    },
  },

  metadata:: $.labels {
    metadata+: {
      namespace: $.namespace,
    },
  },

  crds: std.map(
    (function(o) o + $.labels),
    contour_crds,
  ),

  clusterRole: contour_clusterrole + $.labels,

  serviceAccount: kube.ServiceAccount($.name) + $.metadata {
  },

  clusterRoleBinding: kube.ClusterRoleBinding($.name) + $.metadata {
    roleRef_: $.clusterRole,
    subjects_+: [$.serviceAccount],
  },

  deployment: kube.Deployment($.name) + $.metadata {
    local this = self,
    spec+: {
      replicas: 1,
      template+: {
        metadata+: {
          annotations+: {
            'prometheus.io/scrape': 'true',
            'prometheus.io/port': '8002',
            'prometheus.io/path': '/stats',
            'prometheus.io/format': 'prometheus',
          },
        },
        spec+: {
          serviceAccountName: $.serviceAccount.metadata.name,
          affinity: kube.PodZoneAntiAffinityAnnotation(this.spec.template),
          default_container: 'contour',
          volumes_+: {
            config: kube.EmptyDirVolume(),
          },
          dnsPolicy: 'ClusterFirst',
          initContainers_+: {
            'envoy-init-config': kube.Container('envoy-init-config') {
              image: CONTOUR_IMAGE,
              command: ['contour'],
              args: [
                'bootstrap',
                '/config/contour.json',
              ],
              volumeMounts_+: {
                config: { mountPath: '/config' },
              },
            },
          },
          containers_+: {
            contour: kube.Container('contour') {
              image: CONTOUR_IMAGE,
              command: ['contour'],
              args: [
                'serve',
                '--incluster',
              ],
            },
            envoy: kube.Container('envoy') {
              image: ENVOY_IMAGE,
              command: ['envoy'],
              args: [
                '--config-path /config/contour.json',
                '--service-cluster cluster0',
                '--service-node node0',
                '--log-level info',
                '--v2-config-only',
              ],
              ports_+: {
                http: { containerPort: 8080 },
                https: { containerPort: 8443 },
              },
              readinessProbe: {
                httpGet: { path: '/healthz', port: 8002 },
                initialDelaySeconds: 3,
                periodSeconds: 3,
              },
              lifecycle: {
                preStop: {
                  exec: {
                    command: ['wget', '-qO-', 'http://localhost:9001/healthcheck/fail'],
                  },
                },
              },
              volumeMounts_+: {
                config: { mountPath: '/config' },
              },
            },
          },
        },
      },
    },
  },

  svc: kube._Object('v1', 'Service', $.name) + $.metadata {
    metadata+: {
      annotations+: if $.cloud == 'amazon' then
        {
          'service.beta.kubernetes.io/aws-load-balancer-backend-protocol': 'tcp',
          'service.beta.kubernetes.io/aws-load-balancer-type': 'nlb',
        }
      else
        {},
    },
    spec+: {
      type: 'LoadBalancer',
      selector: $.deployment.spec.template.metadata.labels,
      ports: [
        { name: 'https', targetPort: 8443, port: 443 },
        { name: 'http', targetPort: 8080, port: 80 },
      ],
    },
  },

  // create ingress route
  IngressRoute(namespace, name):: kube._Object(apiGroup + '/' + apiVersion, 'IngressRoute', name) + {
    metadata+: {
      namespace: namespace,
      name: name,
    },
  },

}
