`step-renewer` is a Kubernetes operator that renews Kubernetes `Secret` resources that contain Step CA issued certificates using `step ca renew` and therefore x5c certificate renewal. `step-renewer` will renew the certificates and update the Kubernetes `Secret` with the renewed certificate.

`step-renewer` is a simple and minimal way to renew Step CA certificates in Kubernetes. It does not require providing a JWT provisioner password. It simply follows the same basic renewal instructions that you would use to renew certificates on Linux with `systemd`. It deploys as a single Pod.

The drawback is that there is no automatic issuance of certificates. You need to build and upload a birth certificate but it will then be maintained in perpetuity. This is exactly what I need for a NATS, PostgreSQL or OpenSearch deployment in Kubernetes. They each have a single TLS certificate, the deployments are long lived, and I'm not deploying NATS nor OpenSearch by the thousands.

**Help**: If anyone can see any other advantages or drawbacks of this method over the `cert-manager` and `autocert` and other methods, I'd appreciate your feedback, and I've asked for guidance in the Step CA discussions.

## Install

You can create your own Kubernetes manifests to deploy. In our examples, as in all the Shell Operator examples from the Shell Operator documentation, we're going to use `kubectl` commands to create the namespace and service account.

```
kubectl create namespace step-renewer
kubectl create clusterrole
kubectl create serviceaccount
kubectl create clusterrolebinding
```

You can now create a Kubernetes manifest for the `step-renewer` Pod. You will need to set the following environment variables.

```
apiVersion: v1
kind: Namespace
metadata:
  name: step-renewer
---
apiVersion: v1
kind: Pod
metadata:
  namespace: step-renewer
  name: step-renewer
spec:
  containers:
  - name: step-renewer
    image: flatheadmill/step-renewer:latest
    imagePullPolicy: Always
    env:
    - name: STEP_RENEWER_STEP_CA_URL
      value: https://ca.prettyrobots.net
    - name: STEP_RENEWER_STEP_CA_FINGERPRINT
      value: 6fedeaa92e08e59967b8cb4ead5427b2c51a6ccb45cfe4f504d5af1a3392c16c
    - name: STEP_RENEWER_EXPIRES_IN
      value: '80%'
    - name:  STEP_RENEWER_DEBUG
      value: '1'
    - name: STEP_RENEWER_HUP
      value: |
        #!/usr/bin/env zsh
        case "$1" in
            program/program )
                curl http://my-secure-service.step-renewer/reload-certs
                ;;
        esac
  serviceAccountName: step-renewer
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: step-renewer
  namespace: step-renewer
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: step-renewer
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: step-renewer
subjects:
- kind: ServiceAccount
  name: step-renewer
  namespace: step-renewer
roleRef:
  kind: ClusterRole
  name: step-renewer
  apiGroup: rbac.authorization.k8s.io
```

Step Operator documentation usually shows deployment using Pods instead of Deployments. If this causes a problem I'll come back and update this documentation, if it doesn't I'll come back and let you know that it doesn't really cause a problem.

Now when you create a certificate you need to label it with `step-renewer.prettybobots.com: enabled`. The `step-renewer` will check it according to it's Step Operator `schedule`.

## Configuration

The full set of configuration environment variables are as follows.

| Name                               | Value                                                        |
| ---------------------------------- | ------------------------------------------------------------ |
| `STEP_RENEWER_STEP_CA_URL`         | The URL of the Step CA.                                      |
| `STEP_RENEWER_STEP_CA_FINGERPRINT` | The fingerprint of the Step CA root certificate.             |
| `STEP_RENEWER_EXPIRES_IN`          | The amount of time remaining before certificate expiration, at which point a renewal should be attempted. The certificate renewal will not be performed if the time to expiration is greater than the value. Can be expressed as a percentage of the certificate validity duration. See `step ca renew --help` for more details. |
| `STEP_RENEWER_HUP` | A string containing an interpreted program that will be run after a secret has been updated. The program will be written to file with the executable bit set and executed to reload any services. It should be plain text and start with a shebang line. |
| `STEP_RENEWER_DEBUG`               | (Optional) Print `ca certificate inspect` for each certificate on each scheduled invocation. |
| `STEP_RENEWER_UNSAFE_LOGGING`      | (Optional) **Do not** set this environment variable for production. If set it will print the `_BINDING_CONTEXT` to standard output for use in debugging the application locally. Only use on development clusters with temporary, placeholder certificates. |

To configure you build a container that overwrites the default configuration can mount a different configuration to `/hooks/config.yaml`. The default configuration is to run once every 15 minutes.

## Hacking

The crux of the operator is implemented in  `hooks/step-renewer.zsh`. The entry point is `hooks/hook`. You can debug the application locally with a test cluster using the programs in `debug/`.

The program `debug/renew <namespace>/<secret>` tests renewal against a specific secret in your cluster. Invoke it with the same environment variables used to deploy a pod, plus a `namespace/secret` argument indicating the certificate you want to renew.

```
STEP_RENEWER_EXPIRES_IN='0%' \
  STEP_RENEWER_STEP_CA_URL=https://ca.prettyrobots.com \
  STEP_RENEWER_FINGERPRINT=6fedeaa92e08e59967b8cb4ead5427b2c51a6ccb45cfe4f504d5af1a3392c16c \
    debug/rewnew step-renewer/example
```

The program `debug/binding_context <binding-context>` will run through an example of a binding context. You can capture an example of a binding context by running the `step-renewer` pod with the environment variable `STEP_RENEWER_UNSAFE_LOGGING=1`. **Do not** set this environment variable in a production cluster. Once running, each invocation of the `step-renewer` will print the `BINDING_CONTEXT` to standard output.

Because Shell Operator logs standard output wrapped in JSON, you will need to extract the lines from the JSON. You can get plain standard output with the following command.

```
kubectl -n step-renewer logs step-renewer | jq -r 'select(.output == "stdout") | .msg'
```

The above command simply extracts the standard output from the hook from the JSON formatted logging messages. You will have to copy and paste an example of the binding context into a JSON file. In the example of invocation below we've copied and pasted a binding context example into `binding_context.json`.

```
STEP_RENEWER_EXPIRES_IN='0%' \
  STEP_RENEWER_STEP_CA_URL=https://ca.prettyrobots.com \
  STEP_RENEWER_FINGERPRINT=6fedeaa92e08e59967b8cb4ead5427b2c51a6ccb45cfe4f504d5af1a3392c16c \
    debug/binding_context ./binding_context.json
```
